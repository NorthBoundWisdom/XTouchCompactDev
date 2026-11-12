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

private enum StartupError: Error { case invalidArguments, invalidInstanceID, tokenRequired, tokenFileNotPrivate, readyFileExists, readyFile }

/// JSON-RPC 2.0 failures. Tool failures remain MCP results with `isError: true`.
private struct RPCError: Error {
    let code: Int; let message: String
    static let parse = RPCError(code: -32700, message: "Parse error")
    static let invalidRequest = RPCError(code: -32600, message: "Invalid request")
    static let methodNotFound = RPCError(code: -32601, message: "Method not found")
    static let invalidParams = RPCError(code: -32602, message: "Invalid params")
}

/// The ready file this process created, identified by device and inode so cleanup never
/// removes a file that another process put at the same path. Written once before the
/// signal handlers are installed; read only by async-signal-safe code afterwards.
private nonisolated(unsafe) var ownedReadyPath: UnsafeMutablePointer<CChar>?
private nonisolated(unsafe) var ownedReadyDevice: dev_t = 0
private nonisolated(unsafe) var ownedReadyInode: ino_t = 0

private func removeOwnedReadyFile() {
    guard let path = ownedReadyPath else { return }
    var info = stat()
    if lstat(path, &info) == 0, info.st_dev == ownedReadyDevice, info.st_ino == ownedReadyInode {
        unlink(path)
    }
}

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
            removeOwnedReadyFile()
            FileHandle.standardError.write(Data("XTouchSurfaceSimulator failed: \(error)\n".utf8))
            exit(1)
        }
    }

    /// Same identity rule as the BCR Provider: non-empty, at most 128 bytes, visible ASCII.
    static func validInstanceID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 128 && id.utf8.allSatisfy { (33 ... 126).contains($0) }
    }

    /// Same credential shape as the BCR Provider: exactly 64 lowercase hexadecimal bytes.
    static func validToken(_ token: String) -> Bool {
        token.utf8.count == 64 && token.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) }
    }

    /// A token file must be a regular, non-symlink file owned by this user with no group or
    /// other permission bits. Checks use the opened descriptor, so the path cannot be swapped.
    private static func readPrivateToken(_ path: String) throws -> String {
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { throw StartupError.tokenFileNotPrivate }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0, info.st_size <= 4096 else { throw StartupError.tokenFileNotPrivate }
        var buffer = [UInt8](repeating: 0, count: 4097)
        let count = read(descriptor, &buffer, buffer.count)
        guard count >= 0, count <= 4096 else { throw StartupError.tokenFileNotPrivate }
        return String(decoding: buffer.prefix(count), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Create the ready file exclusively and remember exactly which inode is ours.
    private static func writeReadyFile(_ path: String, _ bytes: Data) throws {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o644)
        guard descriptor >= 0 else { throw errno == EEXIST ? StartupError.readyFileExists : StartupError.readyFile }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { close(descriptor); unlink(path); throw StartupError.readyFile }
        ownedReadyPath = strdup(path); ownedReadyDevice = info.st_dev; ownedReadyInode = info.st_ino
        let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        close(descriptor)
        guard written == bytes.count else { throw StartupError.readyFile }
    }

    /// SIGTERM/SIGINT remove only our ready file, then terminate with the original signal.
    private static func installTerminationCleanup() {
        for value in [SIGTERM, SIGINT] {
            signal(value) { received in
                removeOwnedReadyFile()
                signal(received, SIG_DFL)
                raise(received)
            }
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
            case "--surface-instance-id":
                instance = try value()
                guard validInstanceID(instance) else { throw StartupError.invalidInstanceID }
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
            token = try readPrivateToken(tokenPath)
        } else if tokenStdin {
            token = readLine() ?? ""
        } else {
            throw StartupError.tokenRequired
        }
        guard validToken(token) else { throw StartupError.tokenRequired }
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
        installTerminationCleanup()
        if let readyPath {
            try writeReadyFile(readyPath, readyBytes)
        }
        FileHandle.standardOutput.write(readyBytes + Data("\n".utf8))
        var budget = SurfaceWriteBudget()
        // Leases expire on this process's monotonic clock even without requests. Every request
        // processes due expiries at its own time first, so no read or write observes a pending one.
        func advanceHolds(to time: Double) {
            do { try simulator.processHoldExpiries(at: time) }
            catch { FileHandle.standardError.write(Data("XTouchSurfaceSimulator hold expiry failed: \(error)\n".utf8)) }
        }
        return try server.run(nextDeadline: { simulator.nextHoldDeadline },
                              maintenance: { advanceHolds(to: ProcessInfo.processInfo.systemUptime) })
        { body in
            var id: JSONValue = .null
            do {
                guard let request = try? JSONDecoder().decode(JSONValue.self, from: body) else { throw RPCError.parse }
                guard let object = request.objectValue, object["jsonrpc"] == .string("2.0"), let method = object["method"]?.stringValue else { throw RPCError.invalidRequest }
                if let requestID = object["id"] {
                    guard requestID.stringValue != nil || requestID.finiteNumber != nil || requestID == .null else { throw RPCError.invalidRequest }
                }
                guard object["params"].map({ $0.objectValue != nil || $0.arrayValue != nil }) ?? true else { throw RPCError.invalidRequest }
                // Notifications have no result and never authorize a mutation.
                guard let requestID = object["id"] else { return Data() }
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
                    guard let params = object["params"]?.objectValue, let name = params["name"]?.stringValue else { throw RPCError.invalidParams }
                    do {
                        let operation = try SurfaceControlTools.parse(name, arguments: params["arguments"] ?? .object([:]))
                        let time = ProcessInfo.processInfo.systemUptime
                        advanceHolds(to: time)
                        let value: JSONValue
                        // Mutations run on a copy of the value-type simulator. Only a fully
                        // validated, successful operation consumes the write budget and is committed.
                        func commit(_ candidate: CompactSurfaceSimulator) throws {
                            guard budget.consume(at: time) else { throw ControlContractError("rate_limited") }
                            simulator = candidate
                        }
                        switch operation {
                        case .discover: value = try .encoded(simulator.controls.discovery())
                        case let .snapshot(instanceID):
                            guard instanceID == simulator.controls.expected.instance_id else { throw ControlContractError("instance_mismatch") }
                            value = try .encoded(simulator.controls.snapshot(at: time))
                        case let .input(input):
                            guard allowInput else { throw ControlContractError("permission_denied") }
                            var candidate = simulator
                            let event = try candidate.input(input, at: time)
                            try commit(candidate)
                            value = try .encoded(event)
                        case let .feedback(feedback):
                            guard allowFeedback else { throw ControlContractError("permission_denied") }
                            var candidate = simulator
                            let event = try candidate.feedback(feedback, at: time)
                            try commit(candidate)
                            value = try .encoded(event)
                        case let .renew(request):
                            // Silent lease renewal: input permission and write budget, no sequence or event.
                            guard allowInput else { throw ControlContractError("permission_denied") }
                            var candidate = simulator
                            let renewed = try candidate.renew(request, at: time)
                            try commit(candidate)
                            value = try .encoded(renewed)
                        case let .events(instanceID, epoch, afterSequence, limit):
                            value = try .encoded(simulator.controls.events(instanceID: instanceID, epoch: epoch, afterSequence: afterSequence, limit: limit, at: time))
                        case let .reset(expected, expectedSequence):
                            guard allowReset else { throw ControlContractError("permission_denied") }
                            var candidate = simulator
                            try candidate.reset(expected: expected, expectedSequence: expectedSequence, epoch: UUID().uuidString, at: time)
                            try commit(candidate)
                            value = try .encoded(simulator.controls.discovery())
                        }
                        result = try content(value, isError: false)
                    } catch {
                        let failure = (error as? ControlContractError).map { RemoteFailure(code: $0.code) } ?? RemoteFailure.from(error)
                        result = try content(.encoded(failure), isError: true)
                    }
                default: throw RPCError.methodNotFound
                }
                return try JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": id, "result": result]))
            } catch {
                let failure = error as? RPCError ?? .invalidRequest
                return (try? JSONEncoder().encode(JSONValue.object(["jsonrpc": .string("2.0"), "id": id,
                                                                    "error": .object(["code": .number(failure.code), "message": .string(failure.message)])]))) ?? Data()
            }
        }
    }

    private static func content(_ value: JSONValue, isError: Bool) throws -> JSONValue {
        try .object(["content": .array([.object(["type": .string("text"), "text": .string(value.jsonText)])]), "structuredContent": value, "isError": .bool(isError)])
    }
}
