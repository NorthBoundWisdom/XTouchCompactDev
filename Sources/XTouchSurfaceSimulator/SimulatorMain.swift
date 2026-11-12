import CompactSimulatorTransport
import Foundation
import RemoteToolContracts
import SurfaceControlContracts
import SurfacePluginContracts
import XTouchCompactCore
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

private enum StartupError: Error { case invalidArguments, tokenRequired, readyFileExists }

@main struct SimulatorMain {
    static func main() {
        do {
            if CommandLine.arguments == [CommandLine.arguments[0], "--describe"] {
                let simulator = try CompactSurfaceSimulator(instanceID: "example.simulation", epoch: "discovery-only")
                let value: JSONValue = try .object(["discovery": .encoded(simulator.controls.discovery()),
                                                    "tools": .array(SurfaceControlTools.descriptors.map { try .encoded($0) })])
                try FileHandle.standardOutput.write(JSONEncoder().encode(value) + Data("\n".utf8))
                return
            }
            try run()
        } catch {
            FileHandle.standardError.write(Data("XTouchSurfaceSimulator failed: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() throws -> Never {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var instance = "xtouch.simulation." + UUID().uuidString
        var port: UInt16 = 0
        var tokenPath: String?
        var tokenStdin = false
        var readyPath: String?
        var allowInput = false, allowFeedback = false, allowReset = false
        while !arguments.isEmpty {
            let option = arguments.removeFirst()
            func value() throws -> String {
                guard !arguments.isEmpty else { throw StartupError.invalidArguments }
                return arguments.removeFirst()
            }
            switch option {
            case "--surface-instance-id": instance = try value()
            case "--port": guard let parsed = try UInt16(value()) else { throw StartupError.invalidArguments }; port = parsed
            case "--token-file": tokenPath = try value()
            case "--token-stdin": tokenStdin = true
            case "--ready-file": readyPath = try value()
            case "--allow-surface-input": allowInput = true
            case "--allow-surface-feedback": allowFeedback = true
            case "--allow-surface-reset": allowReset = true
            default: throw StartupError.invalidArguments
            }
        }
        guard tokenPath == nil || !tokenStdin else { throw StartupError.invalidArguments }
        let token: String
        if let tokenPath {
            token = try String(contentsOfFile: tokenPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        } else if tokenStdin {
            token = readLine() ?? ""
        } else {
            throw StartupError.tokenRequired
        }
        guard token.utf8.count >= 16, token.utf8.count <= 4096 else { throw StartupError.tokenRequired }
        if let readyPath, FileManager.default.fileExists(atPath: readyPath) {
            throw StartupError.readyFileExists
        }
        var simulator = try CompactSurfaceSimulator(instanceID: instance, epoch: UUID().uuidString)
        let server = try LoopbackHTTPServer(port: port, token: token)
        let discovery = simulator.controls.discovery()
        let ready: JSONValue = try .object(["expected": .encoded(discovery.expected), "latest_sequence": .string(discovery.latest_sequence),
                                            "source": .string("simulation"), "contract_version": .string(discovery.contract_version)])
        let metadata: JSONValue = .object(["status": .string("ready"), "pid": .number(Int(ProcessInfo.processInfo.processIdentifier)),
                                           "port": .number(Int(server.port)), "url": .string("http://127.0.0.1:\(server.port)/mcp"), "source": .string("simulation"), "surface_control": ready])
        let readyBytes = try JSONEncoder().encode(metadata)
        if let readyPath {
            try readyBytes.write(to: URL(fileURLWithPath: readyPath), options: .withoutOverwriting)
        }
        FileHandle.standardOutput.write(readyBytes + Data("\n".utf8))
        var budget = SurfaceWriteBudget()
        return try server.run { body in
            var id: JSONValue = .null
            do {
                let request = try JSONDecoder().decode(JSONValue.self, from: body)
                guard let object = request.objectValue, object["jsonrpc"] == .string("2.0"), let method = object["method"]?.stringValue else { throw ControlContractError("invalid_request") }
                // Notifications have no result and never authorize a mutation.
                guard let requestID = object["id"] else { return Data() }
                guard requestID.stringValue != nil || requestID.finiteNumber != nil || requestID == .null else { throw ControlContractError("invalid_request") }
                id = requestID
                let result: JSONValue
                switch method {
                case "initialize":
                    let requested = object["params"]?.value(for: "protocolVersion")?.stringValue ?? "2025-11-25"
                    let negotiated = ["2025-11-25", "2026-07-28"].contains(requested) ? requested : "2025-11-25"
                    result = .object(["protocolVersion": .string(negotiated), "capabilities": .object(["tools": .object([:])]), "serverInfo": .object(["name": .string("XTouchSurfaceSimulator"), "version": .string("1.0")])])
                case "ping": result = .object([:])
                case "tools/list":
                    result = .object(["tools": .array(SurfaceControlTools.descriptors.map { tool in
                        .object(["name": .string(tool.name), "description": .string("Explicit software simulation control contract"), "inputSchema": tool.inputSchema,
                                 "outputSchema": tool.outputSchema, "annotations": .object(["readOnlyHint": .bool(!tool.isMutation)])])
                    })])
                case "tools/call":
                    guard let params = object["params"]?.objectValue, let name = params["name"]?.stringValue else { throw ControlContractError("invalid_argument") }
                    do {
                        let operation = try SurfaceControlTools.parse(name, arguments: params["arguments"] ?? .object([:]))
                        let time = ProcessInfo.processInfo.systemUptime
                        let value: JSONValue
                        switch operation {
                        case .discover: value = try .encoded(simulator.controls.discovery())
                        case let .snapshot(instanceID):
                            guard instanceID == simulator.controls.expected.instance_id else { throw ControlContractError("instance_mismatch") }
                            value = try .encoded(simulator.controls.snapshot(at: time))
                        case let .input(input):
                            guard allowInput else { throw ControlContractError("permission_denied") }
                            guard budget.consume(at: time) else { throw ControlContractError("rate_limited") }
                            value = try .encoded(simulator.input(input, at: time))
                        case let .feedback(feedback):
                            guard allowFeedback else { throw ControlContractError("permission_denied") }
                            guard budget.consume(at: time) else { throw ControlContractError("rate_limited") }
                            value = try .encoded(simulator.feedback(feedback, at: time))
                        case let .events(instanceID, epoch, afterSequence, limit):
                            value = try .encoded(simulator.controls.events(instanceID: instanceID, epoch: epoch, afterSequence: afterSequence, limit: limit, at: time))
                        case let .reset(expected, expectedSequence):
                            guard allowReset else { throw ControlContractError("permission_denied") }
                            guard budget.consume(at: time) else { throw ControlContractError("rate_limited") }
                            try simulator.reset(expected: expected, expectedSequence: expectedSequence, epoch: UUID().uuidString, at: time)
                            value = try .encoded(simulator.controls.discovery())
                        }
                        result = try content(value, isError: false)
                    } catch {
                        let failure = (error as? ControlContractError).map { RemoteFailure(code: $0.code) } ?? RemoteFailure.from(error)
                        result = try content(.encoded(failure), isError: true)
                    }
                default: throw ControlContractError("unsupported_method")
                }
                return try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
            } catch {
                return (try? JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "error": .object(["code": .number(-32600), "message": .string("Invalid request")])]))) ?? Data()
            }
        }
    }

    private static func content(_ value: JSONValue, isError: Bool) throws -> JSONValue {
        try .object(["content": .array([.object(["type": .string("text"), "text": .string(value.jsonText)])]), "structuredContent": value, "isError": .bool(isError)])
    }
}
