#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    /// This wrapper records only transport-accepted commands; it never bypasses the model gates.
    @MainActor private final class FieldRecordingMIDI: MIDIService {
        let base: any MIDIService
        var onMessages: (([MIDIMessage]) -> Void)?
        var onConnection: ((CompactMIDIConnection) -> Void)?
        var sent: [MIDIMessage] = []
        var connections: [CompactMIDIConnection] = []
        init(_ base: any MIDIService) {
            self.base = base
            base.onMessages = { [weak self] in self?.onMessages?($0) }
            base.onConnection = { [weak self] connection in
                self?.connections.append(connection)
                self?.onConnection?(connection)
            }
        }

        func start() throws {
            try base.start()
        }

        func select(inputID: Int32?, outputID: Int32?) {
            base.select(inputID: inputID, outputID: outputID)
        }

        func send(_ message: MIDIMessage) throws {
            try base.send(message); sent.append(message)
        }

        func sendPinned(_ message: MIDIMessage, inputID: Int32, outputID: Int32, generation: UInt64) throws {
            try base.sendPinned(message, inputID: inputID, outputID: outputID, generation: generation)
            sent.append(message)
        }
    }

    @MainActor private func fieldMotorCount(_ messages: [MIDIMessage]) -> Int {
        messages.filter {
            if case .controlChange(_, 1 ... 9, _) = $0 {
                true
            } else {
                false
            }
        }.count
    }

    @MainActor private func fieldResult(_ model: ConsoleModel, midi: FieldRecordingMIDI, baseline: Int, eventBaseline: Int) -> [String: Any] {
        let messages = Array(midi.sent.dropFirst(baseline))
        return ["sent_count": messages.count, "motor_cc_count": fieldMotorCount(messages),
                "suppressed_count": model.events.prefix(max(0, model.events.count - eventBaseline)).filter { $0.delivery == .suppressed }.count,
                "agent_motor_grant": model.mcpMotorWritesAllowed,
                "connected": model.connection.isConnected,
                "generation": model.connection.generation,
                "messages": messages.map { String(describing: $0) }]
    }

    @Test @MainActor func fieldMotorSessionMockRehearsal() throws {
        let fake = FakeMIDIService()
        let midi = FieldRecordingMIDI(fake)
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        model.feedbackChannel = 2; model.configure()
        fake.connect(); model.setConsoleMode(.hardwareSend)
        model.mcpWritesAllowed = true; model.mcpMotorWritesAllowed = true
        try model.applyAgentParameter("a.Fader.1", value: 64)
        #expect(fieldMotorCount(midi.sent) == 1)
        fake.onConnection?(CompactMIDIConnection())
        fake.actualGeneration = 1
        fake.onConnection?(CompactMIDIConnection(generation: 1, connectedInput: .init(id: 1, name: "Mock"), connectedOutput: .init(id: 1, name: "Mock")))
        let baseline = midi.sent.count
        let eventBaseline = model.events.count
        try model.applyAgentParameter("a.Fader.1", value: 72)
        model.setParameter("a.Fader.1", value: 73)
        let result = fieldResult(model, midi: midi, baseline: baseline, eventBaseline: eventBaseline)
        #expect(result["motor_cc_count"] as? Int == 0)
        #expect(result["suppressed_count"] as? Int ?? 0 > 0)
        #expect(!model.mcpMotorWritesAllowed)
        model.setConsoleMode(.hardwareSend); model.mcpMotorWritesAllowed = true
        try model.applyAgentParameter("a.Fader.1", value: 68)
        #expect(fieldMotorCount(Array(midi.sent.dropFirst(baseline))) == 1)
    }

    /// Launched only by the attended checklist. Every output action waits for a separate file.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["XTOUCH_FV_ATTENDED"] == "1", "Requires XTOUCH_FV_ATTENDED=1 and an attended stage-file session; default tests never open CoreMIDI"))
    @MainActor func fieldAttendedMotorSession() async throws {
        let rootPath = try #require(ProcessInfo.processInfo.environment["XTOUCH_FV_SESSION"])
        let root = URL(fileURLWithPath: rootPath).standardizedFileURL
        let allowed = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("build/fv/xtouch").standardizedFileURL.path + "/"
        try #require(root.path.hasPrefix(allowed), "Field evidence must stay in build/fv/xtouch")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func write(_ name: String, _ fields: [String: Any]) throws {
            try JSONSerialization.data(withJSONObject: fields, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent(name + ".json"), options: .atomic)
        }
        func signal(_ name: String) async throws {
            let deadline = ProcessInfo.processInfo.systemUptime + 600
            while !FileManager.default.fileExists(atPath: root.appendingPathComponent(name + ".go").path) {
                try #require(ProcessInfo.processInfo.systemUptime < deadline, "Timed out waiting for attended stage \(name)")
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        let midi = FieldRecordingMIDI(CoreMIDIService())
        let model = ConsoleModel(startsMIDI: true, midi: midi, isolated: true)
        model.feedbackChannel = 2; model.configure()
        let deadline = ProcessInfo.processInfo.systemUptime + 15
        while !model.connection.isConnected, ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        try #require(model.connection.isConnected, "Controller input/output unavailable")
        try #require(midi.sent.isEmpty)
        try write("ready", ["sent_count": 0, "input": model.connection.connectedInput?.name ?? "", "output": model.connection.connectedOutput?.name ?? ""])
        try await signal("baseline")
        var baseline = midi.sent.count; var eventBaseline = model.events.count
        model.setConsoleMode(.hardwareSend)
        model.mcpWritesAllowed = true; model.mcpMotorWritesAllowed = true
        try model.applyAgentParameter("a.Fader.1", value: 64)
        try await Task.sleep(for: .milliseconds(400))
        var result = fieldResult(model, midi: midi, baseline: baseline, eventBaseline: eventBaseline)
        result["pass"] = result["motor_cc_count"] as? Int == 1
        try write("baseline", result)
        let route = model.connection.generation
        let connectionBaseline = midi.connections.count
        try await signal("reconnected")
        try #require(midi.connections.dropFirst(connectionBaseline).contains { !$0.isConnected }, "No disconnect callback observed")
        try #require(model.connection.isConnected && model.connection.generation != route, "No new connected route observed")
        baseline = midi.sent.count; eventBaseline = model.events.count
        try model.applyAgentParameter("a.Fader.1", value: 72)
        try await Task.sleep(for: .milliseconds(400))
        result = fieldResult(model, midi: midi, baseline: baseline, eventBaseline: eventBaseline)
        result["agent_suppressed_count"] = result["suppressed_count"]
        let interfaceBaseline = model.events.count
        model.setParameter("a.Fader.1", value: 73)
        result["interface_probe_motor_cc_count"] = fieldMotorCount(Array(midi.sent.dropFirst(baseline)))
        result["interface_probe_suppressed_count"] = model.events.prefix(max(0, model.events.count - interfaceBaseline)).filter { $0.delivery == .suppressed }.count
        result["reconnect_sent_count"] = midi.sent.count - 1
        result["pass"] = result["motor_cc_count"] as? Int == 0 && result["interface_probe_motor_cc_count"] as? Int == 0 && !model.mcpMotorWritesAllowed && (result["interface_probe_suppressed_count"] as? Int ?? 0) > 0
        try write("reconnected", result)
        try await signal("restored")
        baseline = midi.sent.count; eventBaseline = model.events.count
        model.setConsoleMode(.hardwareSend); model.mcpMotorWritesAllowed = true
        try model.applyAgentParameter("a.Fader.1", value: 68)
        try await Task.sleep(for: .milliseconds(400))
        result = fieldResult(model, midi: midi, baseline: baseline, eventBaseline: eventBaseline)
        result["pass"] = result["motor_cc_count"] as? Int == 1
        try write("restored", result)
    }
#endif
