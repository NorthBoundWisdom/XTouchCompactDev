#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    private enum ReconnectedMotorSource: String, CaseIterable {
        case release, interface, mcp, agentWithoutGrant, agentWithGrant, linkedInput
        case scene, undo, redo, layer, configuration, profile, offlineReplay
        case faderSlider, encoderAssignment, buttonAssignment, otherLayerInput, reset
    }

    @MainActor private func motorMessages(_ midi: FakeMIDIService) -> [MIDIMessage] {
        midi.sent.filter {
            if case .controlChange(_, 1 ... 9, _) = $0 {
                true
            } else {
                false
            }
        }
    }

    @MainActor private func replaceMotorRoute(_ midi: FakeMIDIService, outputOnly: Bool) {
        if !outputOnly {
            midi.onConnection?(CompactMIDIConnection())
        }
        midi.actualGeneration = 1
        midi.actualOutputID = outputOnly ? 2 : 1
        let input = CompactMIDIEndpoint(id: 1, name: "Input")
        let output = CompactMIDIEndpoint(id: outputOnly ? 2 : 1, name: "Output")
        midi.onConnection?(CompactMIDIConnection(generation: 1, connectedInput: input, connectedOutput: output))
        midi.sent.removeAll()
    }

    @MainActor private func prepareMotorSource(_ source: ReconnectedMotorSource, model: ConsoleModel, midi: FakeMIDIService) {
        if source == .encoderAssignment || source == .buttonAssignment {
            var config = model.session.parameters.configuration
            let control: CompactControl = source == .encoderAssignment ? .encoder(1) : .button(1)
            config.assignments.removeAll { $0.control == control && $0.layer == .a }
            config.assignments.append(.init(control: control, layer: .a, action: .parameter("a.Fader.1")))
            model.applyConfiguration(config)
        }
        model.mcpWritesAllowed = true
        model.mcpMotorWritesAllowed = source != .agentWithoutGrant
        if source == .linkedInput {
            model.saveLink(.init(id: "reconnect", name: "Link", leader: "a.Fader.1", members: ["a.Fader.2"]))
        }
        model.setParameter("a.Fader.1", value: 40)
        model.captureScene(name: "Reconnect")
        model.setParameter("a.Fader.1", value: 60)
        if source == .redo {
            model.undo()
        }
        if source == .release || source == .linkedInput {
            midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127)])
        }
        if source == .release {
            model.setParameter("a.Fader.1", value: 80)
        }
    }

    @MainActor private func triggerMotorSource(_ source: ReconnectedMotorSource, model: ConsoleModel, midi: FakeMIDIService) throws {
        switch source {
        case .release: midi.onMessages?([.controlChange(channel: 0, number: 101, value: 0)])
        case .faderSlider: model.faderChanged(1, value: 85)
        case .encoderAssignment: model.encoderChanged(1, value: 85)
        case .buttonAssignment: model.pressButton(1)
        case .otherLayerInput: midi.onMessages?([.controlChange(channel: 0, number: 37, value: 85)])
        case .reset: model.resetParameterValues()
        case .interface: model.setParameter("a.Fader.1", value: 85)
        case .mcp:
            _ = try model.routeMCP(["method": "tools/call", "params": ["name": "set_parameter", "arguments": ["id": "a.Fader.1", "value": 85]]])
        case .agentWithoutGrant, .agentWithGrant: try model.applyAgentParameter("a.Fader.1", value: 85)
        case .linkedInput: midi.onMessages?([.controlChange(channel: 0, number: 1, value: 85)])
        case .scene: try model.recallScene(#require(model.session.parameters.configuration.scenes?.first?.id))
        case .undo: model.undo()
        case .redo: model.redo()
        case .layer: model.setLayer(.b)
        case .configuration: model.applyConfiguration(model.session.parameters.configuration)
        case .profile: model.feedbackChannel = 2; model.configure()
        case .offlineReplay:
            let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            let cases = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Fixtures/CaptureReview/cases.json"))) as? [[String: Any]])
            let fixture = try #require(cases.first { $0["name"] as? String == "release-counts" }?["jsonl"] as? String)
            model.importOfflineCapture(data: Data(fixture.utf8), name: "recording.jsonl")
            model.stepOfflineReplay(); model.setOfflineReplayFader(1, value: 100)
            for _ in 0 ..< 4 {
                model.stepOfflineReplay()
            }
        }
    }

    @Test(arguments: ReconnectedMotorSource.allCases, [false, true])
    @MainActor private func reconnectRequiresFreshMotorAction(source: ReconnectedMotorSource, outputOnly: Bool) throws {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(); model.setConsoleMode(.hardwareSend)
        prepareMotorSource(source, model: model, midi: midi)
        replaceMotorRoute(midi, outputOnly: outputOnly)
        try triggerMotorSource(source, model: model, midi: midi)
        #expect(motorMessages(midi).isEmpty, "source=\(source.rawValue), outputOnly=\(outputOnly)")
        #expect(!model.session.state.isMotorPending(1))
        #expect(!model.session.state.isMotorPending(2))
    }

    @Test(arguments: ReconnectedMotorSource.allCases, [false, true])
    @MainActor private func explicitRecallRestoresCurrentConnectionTargets(source: ReconnectedMotorSource, outputOnly: Bool) throws {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(); model.setConsoleMode(.hardwareSend)
        prepareMotorSource(source, model: model, midi: midi)
        replaceMotorRoute(midi, outputOnly: outputOnly)
        try triggerMotorSource(source, model: model, midi: midi)
        // Clear the retained hand explicitly; its old target must not replay on release.
        midi.onMessages?([.controlChange(channel: 0, number: model.layer == .a ? 101 : 111, value: 0)])
        model.realignCurrentLayer()
        midi.sent.removeAll()
        model.recallMotors()
        let value = model.bank.faders[8]
        let channel = model.session.state.map.globalReceiveChannel
        #expect(motorMessages(midi).contains(.controlChange(channel: channel, number: 9, value: value)))
    }

    @Test(arguments: [ReconnectedMotorSource.release, .interface, .mcp, .agentWithGrant, .linkedInput, .undo, .redo, .faderSlider, .encoderAssignment, .buttonAssignment], [false, true])
    @MainActor private func freshConfirmationRestoresMotorSources(source: ReconnectedMotorSource, outputOnly: Bool) throws {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(); model.setConsoleMode(.hardwareSend)
        prepareMotorSource(source, model: model, midi: midi)
        replaceMotorRoute(midi, outputOnly: outputOnly)
        model.setConsoleMode(.hardwareSend)
        if source == .mcp || source == .agentWithGrant {
            model.mcpMotorWritesAllowed = true
        }
        if source == .release {
            model.setParameter("a.Fader.1", value: 85)
        }
        try triggerMotorSource(source, model: model, midi: midi)
        #expect(!motorMessages(midi).isEmpty, "source=\(source.rawValue)")
    }

    @Test @MainActor func suppressedReconnectMotionIsVisibleAndUnchangedStatusCannotConfirmIt() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(); model.setConsoleMode(.hardwareSend)
        replaceMotorRoute(midi, outputOnly: false)
        model.setParameter("a.Fader.1", value: 85)
        #expect(midi.sent.isEmpty && model.error != nil)
        #expect(model.events.contains { $0.delivery == .suppressed && $0.control == .fader(1) })
        let input = CompactMIDIEndpoint(id: 1, name: "Input")
        midi.onConnection?(CompactMIDIConnection(generation: 1, connectedInput: input, connectedOutput: input))
        model.setParameter("a.Fader.1", value: 86)
        #expect(midi.sent.isEmpty)
    }

    @Test @MainActor func confirmationDoesNotResurrectTouchedWritesFromBeforeConfirmation() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(); model.setConsoleMode(.hardwareSend)
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127)])
        replaceMotorRoute(midi, outputOnly: false)
        model.setParameter("a.Fader.1", value: 85)
        #expect(!model.session.state.isMotorPending(1))
        model.setConsoleMode(.hardwareSend)
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 0)])
        #expect(midi.sent.isEmpty)
        model.setParameter("a.Fader.1", value: 86)
        #expect(motorMessages(midi) == [.controlChange(channel: 0, number: 1, value: 86)])
    }

    @Test @MainActor func inputEndpointReplacementAlsoRevokesMotorConfirmation() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(); model.setConsoleMode(.hardwareSend)
        midi.actualInputID = 2
        midi.onConnection?(CompactMIDIConnection(connectedInput: .init(id: 2, name: "New input"), connectedOutput: .init(id: 1, name: "Output")))
        model.setParameter("a.Fader.1", value: 86)
        #expect(midi.sent.isEmpty)
        model.recallMotors()
        #expect(motorMessages(midi).contains(.controlChange(channel: 0, number: 1, value: 86)))
    }

    @Test(arguments: [false, true]) @MainActor func renewedSendModeRestoresParameterMotors(outputOnly: Bool) {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(); model.setConsoleMode(.hardwareSend)
        replaceMotorRoute(midi, outputOnly: outputOnly)
        model.setConsoleMode(.hardwareSend)
        #expect(midi.sent.isEmpty)
        model.setParameter("a.Fader.1", value: 91)
        #expect(motorMessages(midi) == [.controlChange(channel: 0, number: 1, value: 91)])
    }

    @Test(arguments: [false, true]) @MainActor func renewedAgentMotorGrantRestoresOnlyNewWrites(outputOnly: Bool) throws {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(); model.setConsoleMode(.hardwareSend)
        model.mcpMotorWritesAllowed = true
        replaceMotorRoute(midi, outputOnly: outputOnly)
        let grant = try #require(model.panelIntents.setMCPMotorWritesAllowed)
        grant(true)
        #expect(midi.sent.isEmpty)
        try model.applyAgentParameter("a.Fader.1", value: 92)
        #expect(motorMessages(midi) == [.controlChange(channel: 0, number: 1, value: 92)])
    }
#endif
