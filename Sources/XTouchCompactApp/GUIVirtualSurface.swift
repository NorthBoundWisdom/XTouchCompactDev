#if os(macOS)
    import AppKit
    import CoreFoundation
    import Darwin
    import Foundation
    import RemoteToolContracts
    import SurfaceControlContracts
    import SurfacePluginContracts
    import XTouchCompactCore

    enum GUIVirtualError: Error, LocalizedError {
        case invalidBootstrap, forbidden, inactive
        var errorDescription: String? {
            switch self {
            case .invalidBootstrap: "Invalid or timed out GUI virtual surface bootstrap."
            case .forbidden: "GUI virtual surface is permanently simulation only; its display endpoint has been revoked."
            case .inactive: "GUI virtual surface display endpoint is inactive."
            }
        }
    }

    /// Validated before AppKit, user stores or native transport construction.
    struct GUIVirtualOptions: Sendable {
        let token: String
        let readyFD: Int32
        let port: UInt16
        let inputCapacity: Int?

        static func parse(_ arguments: [String]) throws -> Self? {
            let flag = "--gui-virtual-surface"
            guard !arguments.contains(where: { $0.hasPrefix(flag + "=") }) else { throw GUIVirtualError.invalidBootstrap }
            guard arguments.contains(flag) else {
                guard !arguments.contains(where: { $0.hasPrefix("--gui-surface-") }) else { throw GUIVirtualError.invalidBootstrap }
                return nil
            }
            let allowed: Set<String> = [flag, "--gui-surface-capability-fd", "--gui-surface-ready-fd", "--gui-surface-port", "--surface-input-event-capacity"]
            var values: [String: String] = [:]
            var index = 1
            while index < arguments.count {
                let key = arguments[index]
                guard allowed.contains(key), values[key] == nil else { throw GUIVirtualError.invalidBootstrap }
                if key == flag {
                    values[key] = "true"; index += 1; continue
                }
                guard index + 1 < arguments.count else { throw GUIVirtualError.invalidBootstrap }
                values[key] = arguments[index + 1]; index += 2
            }
            guard let capText = values["--gui-surface-capability-fd"], let capability = Int32(capText),
                  let readyText = values["--gui-surface-ready-fd"], let ready = Int32(readyText), capability != ready,
                  let port = UInt16(values["--gui-surface-port"] ?? "0") else { throw GUIVirtualError.invalidBootstrap }
            let capacity = values["--surface-input-event-capacity"].flatMap(Int.init)
            if values["--surface-input-event-capacity"] != nil, capacity.map({ (1 ... 65536).contains($0) }) != true {
                throw GUIVirtualError.invalidBootstrap
            }
            try GUIVirtualFD.validate(capability, writing: false)
            try GUIVirtualFD.validate(ready, writing: true)
            let readyCopy = fcntl(ready, F_DUPFD_CLOEXEC, 3)
            guard readyCopy > 2 else { throw GUIVirtualError.invalidBootstrap }
            do {
                let bytes = try GUIVirtualFD.readFrame(capability)
                guard let text = String(data: bytes, encoding: .utf8), text.filter({ $0 == ":" }).count == 2,
                      let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any], Set(object.keys) == ["schema", "display_token"],
                      let schema = object["schema"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
                      let token = object["display_token"] as? String, token.count == 64, token.allSatisfy({ $0.isASCII && $0.isHexDigit }) else { throw GUIVirtualError.invalidBootstrap }
                close(capability); close(ready)
                return .init(token: token, readyFD: readyCopy, port: port, inputCapacity: capacity)
            } catch { close(readyCopy); throw GUIVirtualError.invalidBootstrap }
        }
    }

    enum GUIVirtualFD {
        static func validate(_ descriptor: Int32, writing: Bool) throws {
            var info = stat()
            let mode = fcntl(descriptor, F_GETFL)
            guard descriptor > 2, mode >= 0, fstat(descriptor, &info) == 0,
                  info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFIFO,
                  mode & O_ACCMODE == (writing ? O_WRONLY : O_RDONLY) else { throw GUIVirtualError.invalidBootstrap }
        }

        /// The private one-shot bootstrap must close within the deadline. Delayed second
        /// frames are rejected just like same-packet extra bytes; no-EOF cannot hang startup.
        static func readFrame(_ descriptor: Int32, timeout: Double = 2) throws -> Data {
            let original = fcntl(descriptor, F_GETFL)
            guard fcntl(descriptor, F_SETFL, original | O_NONBLOCK) == 0 else { throw GUIVirtualError.invalidBootstrap }
            defer { _ = fcntl(descriptor, F_SETFL, original) }
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var bytes = Data()
            var buffer = [UInt8](repeating: 0, count: 4097)
            while ProcessInfo.processInfo.systemUptime < deadline {
                let count = Darwin.read(descriptor, &buffer, buffer.count)
                if count > 0 {
                    bytes.append(contentsOf: buffer.prefix(count))
                    guard bytes.count <= 4096 else { throw GUIVirtualError.invalidBootstrap }
                } else if count == 0 {
                    guard bytes.last == 10, bytes.filter({ $0 == 10 }).count == 1 else { throw GUIVirtualError.invalidBootstrap }
                    return bytes.dropLast()
                } else if errno != EAGAIN, errno != EINTR {
                    throw GUIVirtualError.invalidBootstrap
                }
                var item = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                _ = poll(&item, 1, 10)
            }
            throw GUIVirtualError.invalidBootstrap
        }

        /// Called off MainActor. Backpressure has a deadline and never becomes false ready.
        static func writeFrame(_ bytes: Data, to descriptor: Int32, timeout: Double = 2) throws {
            defer { close(descriptor) }
            guard bytes.count <= 32768, fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK) == 0 else { throw GUIVirtualError.invalidBootstrap }
            _ = fcntl(descriptor, F_SETNOSIGPIPE, 1)
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            var offset = 0
            while offset < bytes.count, ProcessInfo.processInfo.systemUptime < deadline {
                let count = bytes.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
                if count > 0 {
                    offset += count
                } else if count < 0, errno != EAGAIN, errno != EINTR {
                    throw GUIVirtualError.invalidBootstrap
                }
                var item = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                if offset < bytes.count {
                    _ = poll(&item, 1, 10)
                }
            }
            guard offset == bytes.count else { throw GUIVirtualError.invalidBootstrap }
        }
    }

    /// These objects cannot construct a native MIDI/OSC transport, even after a mode-change attempt.
    @MainActor final class GUIVirtualMIDI: MIDIService {
        var onMessages: (([MIDIMessage]) -> Void)?
        var onConnection: ((CompactMIDIConnection) -> Void)?
        func start() throws {
            throw GUIVirtualError.forbidden
        }

        func select(inputID _: Int32?, outputID _: Int32?) {}
        func send(_: MIDIMessage) throws {
            throw GUIVirtualError.forbidden
        }

        func sendPinned(_: MIDIMessage, inputID _: Int32, outputID _: Int32, generation _: UInt64) throws {
            throw GUIVirtualError.forbidden
        }
    }

    @MainActor final class GUIVirtualOSC: OSCTransport {
        func start(host _: String, port _: UInt16, onFailure _: @escaping (any Error) -> Void) throws {
            throw GUIVirtualError.forbidden
        }

        func send(_: Data) {}
        func stop() {}
    }

    /// Only the shared control journal is owned here. The model owns the sole session and Mock.
    @MainActor final class CompactGUIVirtualSurfacePort {
        static let profileID = "xtouch.compact.gui.virtual"
        private(set) var controls: SurfaceControlSession
        private(set) var active = true
        private weak var model: ConsoleModel?
        private let listener = LocalMCPServer(requestLimit: 4096)
        private var budget = SurfaceWriteBudgets()
        private var feedbackInFlight = false
        private var readyPublished = false
        private var readyDescriptor: Int32?
        private let interfaceWriter = "gui.interface.\(UUID().uuidString)"
        private let displayWriter = "gui.display.\(UUID().uuidString)"
        private let capacity: Int?
        private let clock: () -> Double

        init(model: ConsoleModel, inputCapacity: Int? = nil, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) throws {
            self.model = model; capacity = inputCapacity; self.clock = clock
            controls = try SurfaceControlSession(instanceID: UUID().uuidString, epoch: UUID().uuidString,
                                                 profile: Self.profile(model.session.parameters.configuration, inputCapacity: inputCapacity), inputEventCapacity: inputCapacity)
        }

        static func profile(_ configuration: SurfaceConfiguration, inputCapacity: Int?) -> ControlProfile {
            let original = CompactSurfaceSimulator.profile(configuration: configuration, inputEventCapacity: inputCapacity)
            let descriptors = original.controls.filter { !$0.id.contains(".expression.") && !$0.id.contains(".footswitch.") }.map {
                ControlDescriptor(id: $0.id, inputKind: $0.input_kind, encoding: $0.encoding, range: $0.range, feedbackRange: $0.feedback_range,
                                  feedbackKinds: $0.feedback_kinds, mapping: $0.mapping, acceptsInput: true)
            }
            return .init(id: profileID, version: "1", controls: descriptors,
                         capabilities: original.capabilities.filter { $0 != "input.hold" } + ["x.xtouch.gui_virtual"])
        }

        func start(_ options: GUIVirtualOptions) throws {
            readyDescriptor = options.readyFD
            listener.readSource = { "simulation" }
            listener.handler = { [weak self] request in guard let self else { throw GUIVirtualError.inactive }; return try route(request) }
            listener.onError = { [weak self] error in self?.fail(error) }
            listener.onReady = { [weak self] port in
                guard let self, active, let readyFD = readyDescriptor else { return }
                readyDescriptor = nil // The bounded writer owns this descriptor from here.
                do {
                    let discovery = controls.discovery()
                    let value: JSONValue = try .object(["schema": .number(1), "event": .string("gui_virtual_ready"), "url": .string("http://127.0.0.1:\(port)/mcp"),
                                                        "source": .string("simulation"), "profile": .string(Self.profileID), "physical_evidence": .bool(false),
                                                        "surface_control": .object(["expected": .encoded(discovery.expected), "contract_version": .string(discovery.contract_version)])])
                    let bytes = try JSONEncoder().encode(value) + Data([10])
                    Task { @MainActor [weak self] in
                        do {
                            guard self?.active == true else { close(readyFD); return }
                            try await Task.detached { try GUIVirtualFD.writeFrame(bytes, to: readyFD) }.value
                            self?.readyPublished = true
                        } catch { self?.fail(error); exit(2) }
                    }
                } catch { close(readyFD); fail(error); exit(2) }
            }
            do { try listener.start(port: options.port, token: options.token) }
            catch { revoke(); throw error }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self, active, !readyPublished else { return }
                fail(GUIVirtualError.invalidBootstrap)
                exit(2)
            }
            model?.logGUIVirtual("GUI virtual surface: source simulation; physical_evidence=false")
        }

        func revoke() {
            guard active else { return }
            listener.revokeAuthentication() // Drop authentication and pending peers first.
            if let descriptor = readyDescriptor {
                close(descriptor); readyDescriptor = nil
            }
            active = false
            do {
                controls = try SurfaceControlSession(instanceID: controls.expected.instance_id, epoch: UUID().uuidString,
                                                     profile: controls.profile, inputEventCapacity: capacity)
            } catch { model?.reportGUIVirtualError(error) }
            model?.clearGUIVirtualDisplay()
        }

        func fail(_ error: any Error) {
            revoke(); model?.reportGUIVirtualError(error)
        }

        func commit(_ next: SurfaceControlSession) {
            controls = next
        }

        func journal(_ messages: [MIDIMessage], before: CompactSession, candidate _: CompactSession) throws -> SurfaceControlSession {
            guard active else { throw GUIVirtualError.inactive }
            var next = controls
            for message in messages {
                guard let raw = before.state.map.decode(message), let (kind, index) = Self.address(raw.control) else { continue }
                let id = "\(raw.layer.rawValue).\(kind).\(index)"
                guard let descriptor = next.profile.controls.first(where: { $0.id == id }) else { throw ControlContractError("unsupported_control") }
                let input = ControlInput(expected: next.expected, expectedInputSequence: next.discovery().latest_input_sequence, controlID: id,
                                         encoding: descriptor.encoding.rawValue, value: raw.isPressed.map(JSONValue.bool) ?? .number(Int(raw.value)))
                let unchanged = next.isUnchanged(input)
                _ = try next.recordInput(input, disposition: unchanged ? .ignored : .accepted, reason: unchanged ? "no_change" : nil,
                                         origin: .interface, at: clock(), writerID: interfaceWriter)
            }
            return next
        }

        func layerJournal(_ layer: CompactLayer) throws -> SurfaceControlSession {
            guard active else { throw GUIVirtualError.inactive }
            var next = controls
            for down in [true, false] {
                let input = ControlInput(expected: next.expected, expectedInputSequence: next.discovery().latest_input_sequence,
                                         controlID: "global.layer.\(layer.rawValue)", encoding: "boolean", value: .bool(down))
                _ = try next.recordInput(input, disposition: .accepted, origin: .interface, at: clock(), writerID: interfaceWriter)
            }
            return next
        }

        static func address(_ control: CompactControl) -> (String, Int)? {
            switch control {
            case let .fader(i): ("fader", i)
            case let .faderTouch(i): ("touch", i)
            case let .encoder(i): ("encoder", i)
            case let .encoderPush(i): ("push", i)
            case let .button(i): ("button", i)
            case .expression, .footswitch: nil
            }
        }

        func route(_ request: [String: Any]) throws -> [String: Any] {
            guard active, let model else { throw GUIVirtualError.inactive }
            let allowed = Set(["surface_control_discover", "surface_control_snapshot", "surface_control_events", "surface_control_feedback"])
                .union(capacity == nil ? [] : [SurfaceControlInputEventsTools.name])
            if request["method"] as? String == "tools/list" {
                let descriptors = SurfaceControlTools.descriptors + (capacity == nil ? [] : SurfaceControlInputEventsTools.descriptors(source: .simulation))
                let tools = descriptors.filter { allowed.contains($0.name) }.map { tool in
                    JSONValue.object(["name": .string(tool.name), "description": .string("GUI virtual surface; simulation only; display scope"), "inputSchema": tool.inputSchema,
                                      "outputSchema": tool.outputSchema, "annotations": .object(["readOnlyHint": .bool(!tool.isMutation)])])
                }
                return try dictionary(.object(["tools": .array(tools)]))
            }
            guard request["method"] as? String == "tools/call" else { throw MCPError.methodNotFound }
            do {
                guard let params = request["params"] as? [String: Any], let name = params["name"] as? String, allowed.contains(name) else { throw ControlContractError("permission_denied") }
                let arguments = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: params["arguments"] ?? [:]))
                let time = clock()
                let value: JSONValue
                if name == SurfaceControlInputEventsTools.name {
                    let call = try SurfaceControlInputEventsTools.parse(name, arguments: arguments)
                    value = try .encoded(controls.inputEvents(expected: call.expected, afterInputSequence: call.after_input_sequence, limit: call.limit, at: time))
                } else {
                    switch try SurfaceControlTools.parse(name, arguments: arguments) {
                    case .discover: value = try .encoded(controls.discovery())
                    case let .snapshot(id):
                        guard id == controls.expected.instance_id else { throw ControlContractError("instance_mismatch") }
                        value = try .encoded(controls.snapshot(at: time))
                    case let .events(id, epoch, sequence, limit): value = try .encoded(controls.events(instanceID: id, epoch: epoch, afterSequence: sequence, limit: limit, at: time))
                    case let .feedback(feedback):
                        guard !feedbackInFlight else { throw ControlContractError("permission_denied") }
                        feedbackInFlight = true
                        defer { feedbackInFlight = false }
                        var next = controls
                        try next.validateFeedback(feedback, at: time, writerID: displayWriter)
                        let parts = feedback.control_id.split(separator: ".")
                        guard parts.count == 3, let index = Int(parts[2]), let layer = CompactLayer(rawValue: String(parts[0])) else { throw ControlContractError("unsupported_feedback") }
                        try model.validateGUIVirtualDisplayPolicy(kind: String(parts[1]))
                        let activeLayer = layer == model.session.state.layer
                        let event = try next.recordFeedback(feedback, disposition: activeLayer ? .accepted : .ignored, reason: activeLayer ? nil : "inactive_layer", origin: .remote, at: time, writerID: displayWriter)
                        var nextBudget = budget
                        guard nextBudget.consume(.feedback, at: time, writerID: displayWriter) else { throw ControlContractError("rate_limited") }
                        if activeLayer {
                            try model.commitGUIVirtualFeedback(feedback, kind: String(parts[1]), index: index, journal: next)
                        } else {
                            controls = next
                        }
                        budget = nextBudget
                        value = try .encoded(event)
                    default: throw ControlContractError("permission_denied")
                    }
                }
                return try content(value, isError: false)
            } catch {
                let failure = (error as? ControlContractError).map { RemoteFailure(code: $0.code) } ?? RemoteFailure.from(error)
                return try content(.encoded(failure), isError: true)
            }
        }

        private func content(_ value: JSONValue, isError: Bool) throws -> [String: Any] {
            try dictionary(.object(["content": .array([.object(["type": .string("text"), "text": .string(value.jsonText)])]), "structuredContent": value, "isError": .bool(isError)]))
        }

        private func dictionary(_ value: JSONValue) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as! [String: Any]
        }
    }
#endif
