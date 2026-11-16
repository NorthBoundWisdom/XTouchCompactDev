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

private enum StartupError: Error { case invalidArguments, invalidInstanceID, tokenRequired, tokenStdinNotPipe, tokenFileNotPrivate, readyFileExists, readyFile, testMIDIRequiresDebugBuild }

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
// Keep this inode alive until process exit. Closing it after creation lets Linux reuse the
// inode for an unrelated replacement at the same path, defeating the ownership check.
private nonisolated(unsafe) var ownedReadyDescriptor: Int32 = -1
// Disabled-mode cleanup evidence is pre-encoded before installing handlers. The handler
// performs only write/lstat/unlink/signal/raise; no locks, allocation or JSON encoding.
private nonisolated(unsafe) var disabledCleanupBytes: UnsafeMutablePointer<UInt8>?
private nonisolated(unsafe) var disabledCleanupCount = 0

private func removeOwnedReadyFile() {
    if let bytes = disabledCleanupBytes {
        _ = write(STDERR_FILENO, bytes, disabledCleanupCount)
    }
    guard ownedReadyDescriptor >= 0, let path = ownedReadyPath else { return }
    var info = stat()
    if lstat(path, &info) == 0, info.st_dev == ownedReadyDevice, info.st_ino == ownedReadyInode {
        unlink(path)
    }
}

@main struct HardwareMain {
    static func main() {
        do {
            try run()
        } catch {
            removeOwnedReadyFile()
            FileHandle.standardError.write(Data("XTouchSurfaceHardware failed: \(error)\n".utf8))
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
        ownedReadyDescriptor = descriptor
        let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
        // The descriptor is intentionally held for this process lifetime (see ownership guard).
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

    private static func run() throws {
        var arguments = Array(CommandLine.arguments.dropFirst())
        var instance = "xtouch.hardware." + UUID().uuidString
        var port: UInt16 = 0
        var tokenPath: String?
        var tokenStdin = false
        var clientTokensStdin = false
        var readyPath: String?
        var deviceName = "X-TOUCH COMPACT"
        var deviceAccess: HardwareDeviceAccess = .enabled
        var explicitDeviceAccess = false
        var receiveChannel: UInt8?
        var transmitChannel: UInt8 = 0
        var lights: ButtonLightProtocol?
        var describe = false
        var writeLimit = SurfaceWriteBudget.writesPerSecond
        var explicitWriteLimit = false
        var writeLimits: ControlWriteLimits?
        var principalPath: String?
        var allowFeedback = false
        while !arguments.isEmpty {
            let option = arguments.removeFirst()
            func value() throws -> String {
                guard !arguments.isEmpty else { throw StartupError.invalidArguments }
                return arguments.removeFirst()
            }
            switch option {
            case "--surface-principal-file": principalPath = try value()
            case "--write-limits":
                guard writeLimits == nil else { throw StartupError.invalidArguments }
                var limits: [String: Int] = [:]
                for item in try value().split(separator: ",", omittingEmptySubsequences: false) {
                    let pair = item.split(separator: "=", omittingEmptySubsequences: false)
                    guard pair.count == 2, ["input", "feedback", "renew", "admin"].contains(String(pair[0])),
                          limits[String(pair[0])] == nil, let limit = Int(pair[1]), (1 ... 10000).contains(limit)
                    else { throw StartupError.invalidArguments }
                    limits[String(pair[0])] = limit
                }
                guard limits.count == 4 else { throw StartupError.invalidArguments }
                writeLimits = .init(inputPerWindow: limits["input"]!, feedbackPerWindow: limits["feedback"]!, renewPerWindow: limits["renew"]!, adminPerWindow: limits["admin"]!)
            case "--write-limit":
                explicitWriteLimit = true
                guard let limit = try Int(value()), (1 ... 10000).contains(limit) else { throw StartupError.invalidArguments }
                writeLimit = limit
            case "--device-access":
                guard !explicitDeviceAccess, let parsed = try HardwareDeviceAccess(rawValue: value()) else { throw StartupError.invalidArguments }
                deviceAccess = parsed; explicitDeviceAccess = true
            case "--describe": describe = true
            case "--device": deviceName = try value(); guard !deviceName.isEmpty else { throw StartupError.invalidArguments }
            case "--receive-channel": guard let channel = try UInt8(value()), (1 ... 16).contains(channel) else { throw StartupError.invalidArguments }; receiveChannel = channel - 1
            case "--transmit-channel": guard let channel = try UInt8(value()), (1 ... 16).contains(channel) else { throw StartupError.invalidArguments }; transmitChannel = channel - 1
            case "--light-protocol": guard let parsed = try ButtonLightProtocol(rawValue: value()) else { throw StartupError.invalidArguments }; lights = parsed
            case "--help":
                print("XTouchSurfaceHardware --receive-channel 1..16 --light-protocol manual|observed114 [--transmit-channel 1..16] [--device NAME] [--device-access enabled|disabled] [--token-file PATH|--token-stdin] [--port 0] [--ready-file PATH] [--surface-instance-id ID] [--surface-principal-file PATH] [--surface-client-tokens-stdin] [--write-limit N|--write-limits input=N,feedback=N,renew=N,admin=N] [--allow-surface-feedback] [--describe]\nDisplay only; no motor, layer or mode output. Display feedback defaults off.\n--device-access disabled is immutable offline diagnostics: no MIDI creation/enumeration/connection or scripted inputs; permanently disconnected, no physical qualification.")
                return
            case "--surface-instance-id":
                instance = try value()
                guard validInstanceID(instance) else { throw StartupError.invalidInstanceID }
            case "--port": guard let parsed = try UInt16(value()) else { throw StartupError.invalidArguments }; port = parsed
            case "--token-file": tokenPath = try value()
            case "--token-stdin": tokenStdin = true
            case "--surface-client-tokens-stdin": clientTokensStdin = true
            case "--ready-file": readyPath = try value()
            case "--allow-surface-feedback": allowFeedback = true
            default: throw StartupError.invalidArguments
            }
        }
        guard !explicitWriteLimit || writeLimits == nil, let receiveChannel, let lights else { throw StartupError.invalidArguments }
        let environment = ProcessInfo.processInfo.environment
        let injectionRequested = environment["XTOUCH_HARDWARE_TEST_SCRIPT"] != nil || environment["XTOUCH_HARDWARE_TEST_REPORT"] != nil
        guard deviceAccess != .disabled || !injectionRequested else { throw HardwareDeviceAccess.SelectionError.disabledRejectsTestInjection }
        let configuration = try CompactHardwareConfiguration(transmitChannel: transmitChannel, receiveChannel: receiveChannel, lightProtocol: lights)
        guard !clientTokensStdin || (!tokenStdin && tokenPath == nil) else { throw StartupError.invalidArguments }
        if describe {
            let surface = try CompactHardwareSurface(instanceID: "example.hardware", epoch: "discovery-only", configuration: configuration, hardwareWriterID: "hardware.example", remoteWriterID: "remote.example", writeLimits: writeLimits)
            let value: JSONValue = try .object(["device_access": .string(deviceAccess.rawValue), "diagnostic_only": .bool(deviceAccess == .disabled), "discovery": .encoded(surface.controls.discovery()), "tools": .array(SurfaceControlTools.descriptors(source: .hardware).map { try .encoded($0) })])
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            try FileHandle.standardOutput.write(encoder.encode(value) + Data("\n".utf8))
            return
        }
        guard tokenPath == nil || !tokenStdin else { throw StartupError.invalidArguments }
        var credentials = try clientTokensStdin ? SurfaceClientCredentials.readStdin() : nil
        let token: String
        if let credentials {
            token = credentials.ownerToken
        } else if let tokenPath {
            token = try readPrivateToken(tokenPath)
        } else if tokenStdin {
            // Same rule as the BCR Provider: stdin must be a dedicated pipe. A redirected file
            // would bypass the private-file checks of --token-file; a terminal would echo it.
            var info = stat()
            guard fstat(STDIN_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else { throw StartupError.tokenStdinNotPipe }
            token = readLine() ?? ""
        } else {
            throw StartupError.tokenRequired
        }
        guard validToken(token) else { throw StartupError.tokenRequired }
        if let readyPath, FileManager.default.fileExists(atPath: readyPath) {
            throw StartupError.readyFileExists
        }
        let principals = try SurfacePrincipals.loadOrCreate(path: principalPath)
        credentials = credentials?.reservingWriterIDs([principals.remote_writer_id, principals.interface_writer_id, principals.system_writer_id])
        var surface = try CompactHardwareSurface(instanceID: instance, epoch: UUID().uuidString, configuration: configuration,
                                                 hardwareWriterID: principals.interface_writer_id, remoteWriterID: principals.remote_writer_id, writeLimits: writeLimits)
        let audit = DeviceAccessAudit(access: deviceAccess)
        let testOnly = environment["XTOUCH_HARDWARE_TEST_SCRIPT"] != nil
        let midi: any HardwareMIDI = try deviceAccess.make(testInjectionRequested: injectionRequested, disabled: {
            DisabledHardwareMIDI()
        }, enabled: {
            if injectionRequested {
                #if DEBUG
                    guard let path = environment["XTOUCH_HARDWARE_TEST_SCRIPT"] else { throw StartupError.invalidArguments }
                    audit.increment("scripted_factory_calls")
                    FileHandle.standardError.write(Data("TEST ONLY MIDI: not an entity device; no physical qualification.\n".utf8))
                    return try ScriptedHardwareMIDI(path: path, report: environment["XTOUCH_HARDWARE_TEST_REPORT"], timingPath: environment["XTOUCH_HARDWARE_TEST_TIMING"], configuration: configuration)
                #else
                    // A release service must never swap its device for a local script.
                    throw StartupError.testMIDIRequiresDebugBuild
                #endif
            }
            audit.increment("coremidi_factory_calls")
            return try CoreHardwareMIDI(deviceName: deviceName, configuration: configuration, audit: audit)
        })
        // After an invalidating error, ask the transport to re-establish the link (a new epoch)
        // instead of staying disconnected until the endpoint happens to change.
        var recoverAfter: Double?
        func drainMIDI() {
            if let deadline = recoverAfter, ProcessInfo.processInfo.systemUptime >= deadline {
                recoverAfter = nil
                midi.invalidate()
            }
            do {
                for event in try midi.drain() {
                    let time = ProcessInfo.processInfo.systemUptime
                    switch event {
                    case let .link(connected): try surface.transition(epoch: UUID().uuidString, connected: connected, at: time)
                    case let .message(message): _ = try surface.receive(message, at: time)
                    case .undecoded: FileHandle.standardError.write(Data("Undecoded device packet\n".utf8))
                    }
                }
            } catch {
                let now = ProcessInfo.processInfo.systemUptime
                try? surface.transition(epoch: UUID().uuidString, connected: false, at: now)
                recoverAfter = now + 1
                FileHandle.standardError.write(Data("Hardware input invalidated; rediscover and prepare again.\n".utf8))
            }
        }
        drainMIDI()
        if deviceAccess == .disabled {
            let bytes = audit.line("device_access_disabled_cleanup")
            disabledCleanupCount = bytes.count
            disabledCleanupBytes = .allocate(capacity: bytes.count)
            bytes.copyBytes(to: disabledCleanupBytes!, count: bytes.count)
        }
        audit.emit("device_access_startup")
        let server = try LoopbackHTTPServer(port: port, token: token, credentials: credentials)
        let discovery = surface.controls.discovery()
        let ready: JSONValue = try .object(["expected": .encoded(discovery.expected), "latest_sequence": .string(discovery.latest_sequence),
                                            "source": .string("hardware"), "contract_version": .string(discovery.contract_version)])
        let metadata: JSONValue = .object(["status": .string("ready"), "pid": .number(Int(ProcessInfo.processInfo.processIdentifier)),
                                           "port": .number(Int(server.port)), "url": .string("http://127.0.0.1:\(server.port)/mcp"), "source": .string("hardware"), "test_only": .bool(testOnly), "device_access": .string(deviceAccess.rawValue), "diagnostic_only": .bool(deviceAccess == .disabled), "device_io": .object(audit.snapshot.mapValues(JSONValue.number)), "surface_control": ready])
        let readyBytes = try JSONEncoder().encode(metadata)
        installTerminationCleanup()
        if let readyPath {
            try writeReadyFile(readyPath, readyBytes)
        }
        FileHandle.standardOutput.write(readyBytes + Data("\n".utf8))
        var budget = writeLimits.map { SurfaceWriteBudgets(input: $0.input_per_window, feedback: $0.feedback_per_window, renew: $0.renew_per_window, admin: $0.admin_per_window) }
            ?? SurfaceWriteBudgets(aggregateLimit: writeLimit)
        var nextPoll = ProcessInfo.processInfo.systemUptime + 0.02
        try server.runAuthenticated(nextDeadline: { nextPoll }, maintenance: {
            drainMIDI()
            nextPoll = ProcessInfo.processInfo.systemUptime + 0.02
        }) { body, client in
            var auditOperation = "unparsed"
            defer {
                if deviceAccess == .disabled {
                    audit.emit("device_access_request_complete", operation: auditOperation)
                }
            }
            var id: JSONValue = .null
            do {
                guard let request = try? JSONDecoder().decode(JSONValue.self, from: body) else { throw RPCError.parse }
                guard let object = request.objectValue, object["jsonrpc"] == .string("2.0"), let method = object["method"]?.stringValue else { throw RPCError.invalidRequest }
                auditOperation = ["initialize", "ping", "tools/list", "notifications/initialized"].contains(method) ? method : "unsupported"
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
                    result = .object(["protocolVersion": .string(negotiated), "capabilities": .object(["tools": .object([:])]), "serverInfo": .object(["name": .string("XTouchSurfaceHardware"), "version": .string("1.0")])])
                case "ping": result = .object([:])
                case "tools/list":
                    result = .object(["tools": .array(SurfaceControlTools.descriptors(source: .hardware).filter { client.permits($0.name) }.map { tool in
                        .object(["name": .string(tool.name), "description": .string("Hardware observations and display-only feedback"), "inputSchema": tool.inputSchema,
                                 "outputSchema": tool.outputSchema, "annotations": .object(["readOnlyHint": .bool(!tool.isMutation)])])
                    })])
                case "tools/call":
                    guard let params = object["params"]?.objectValue, let name = params["name"]?.stringValue else { throw RPCError.invalidParams }
                    if SurfaceControlTools.descriptors(source: .hardware).contains(where: { $0.name == name }) {
                        auditOperation = name
                    }
                    do {
                        guard client.permits(name) else { throw ControlContractError("permission_denied") }
                        let operation = try SurfaceControlTools.parse(name, arguments: params["arguments"] ?? .object([:]))
                        drainMIDI()
                        let time = ProcessInfo.processInfo.systemUptime
                        let value: JSONValue
                        switch operation {
                        case .discover: value = try .encoded(surface.controls.discovery())
                        case let .snapshot(instanceID):
                            guard instanceID == surface.controls.expected.instance_id else { throw ControlContractError("instance_mismatch") }
                            value = try .encoded(surface.controls.snapshot(at: time))
                        case let .input(input):
                            try surface.controls.validateInput(input, at: time, writerID: principals.remote_writer_id)
                            throw ControlContractError("permission_denied")
                        case let .feedback(feedback):
                            let plan = try surface.displayPlan(feedback, allowed: allowFeedback, at: time, writerID: client.writerID)
                            var candidate = surface
                            let event = try candidate.recordFeedback(feedback, at: time, writerID: client.writerID)
                            guard budget.consume(.feedback, at: time) else { throw ControlContractError("rate_limited") }
                            // Spent before any send: a partly delivered or failing request is still
                            // rate limited. The event commits only after every message was accepted.
                            for message in plan {
                                try midi.send(message)
                            }
                            surface = candidate
                            value = try .encoded(event)
                        case let .renew(request):
                            try surface.controls.validateRenew(request, at: time)
                            throw ControlContractError("unsupported_hold")
                        case let .events(instanceID, epoch, afterSequence, limit):
                            value = try .encoded(surface.controls.events(instanceID: instanceID, epoch: epoch, afterSequence: afterSequence, limit: limit, at: time))
                        case let .reset(expected, expectedSequence):
                            var rejected = surface.controls
                            try rejected.reset(expected: expected, expectedSequence: expectedSequence, epoch: UUID().uuidString, at: time)
                            throw ControlContractError("unsupported_tool")
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
