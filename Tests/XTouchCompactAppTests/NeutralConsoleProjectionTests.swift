#if os(macOS)
    import Foundation
    import SurfaceDeviceContracts
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @MainActor private func neutralConsole() throws -> (ConsoleModel, FakeMIDIService) {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, now: { Date(timeIntervalSince1970: 99999) }, isolated: true,
                                 eventMonotonicClock: { 12 }, pluginRegistryEpoch: "fixture.actual.registry.epoch")
        model.apply { try $0.loadConfiguration(.init(parameters: [.init(id: "p", name: "P", minimum: 0, maximum: 127, defaultValue: 0)], assignments: [.init(control: .encoder(1), layer: .a, action: .parameter("p"))]), resetValues: true) }
        midi.connect(); model.setConsoleMode(.hardwareSend); model.clearMonitor()
        return (model, midi)
    }

    @Test @MainActor func neutralAgentOutputUsesCapturedHardwareSourceAndNeverCurrentModeOrWallDate() throws {
        let (model, _) = try neutralConsole()
        try model.applyAgentParameter("p", value: 80)
        let event = try #require(model.events.first { $0.direction == .output && $0.source == .agent })
        let projected = try ConsoleNeutralProjection.feedback(event, instanceID: "fixture")
        let effect = try #require(projected)
        #expect(event.source == .agent && effect.source == .hardware)
        #expect(effect.at == 12 && event.timestamp.timeIntervalSince1970 == 99999)
        #expect(effect.context.generation.contains("binding:"))
        #expect(try ConsoleNeutralProjection.input(event, instanceID: "fixture") == nil)
        model.setLayer(.b); model.setConsoleMode(.mock)
        #expect(try ConsoleNeutralProjection.feedback(event, instanceID: "fixture") == effect)
        let registry = try model.plugins.remoteEventSnapshot()
        #expect(registry.epoch == "fixture.actual.registry.epoch")
    }

    @Test @MainActor func neutralProjectionRejectsMissingReceiptFactsRatherThanInferringAgentSource() throws {
        let (model, _) = try neutralConsole()
        try model.applyAgentParameter("p", value: 80)
        var event = try #require(model.events.first { $0.direction == .output && $0.source == .agent })
        event.monotonicTime = nil
        #expect(throws: CompactNeutralProjectionError.self) { try ConsoleNeutralProjection.feedback(event, instanceID: "fixture") }
        event.monotonicTime = 12; event.deviceSource = nil
        #expect(throws: CompactNeutralProjectionError.self) { try ConsoleNeutralProjection.feedback(event, instanceID: "fixture") }
    }

    @Test @MainActor func actualMutationWitnessSurvivesMonitorClearingAndRunsAfterRealIO() throws {
        let (model, midi) = try neutralConsole()
        var facts: [ConsoleMutationFact] = []
        var afterIO: [Bool] = []
        model.observeMutation = { fact in facts.append(fact); afterIO.append(!midi.sent.isEmpty) }
        model.setParameter("p", value: 80); model.clearMonitor()
        model.setParameter("p", value: 80); model.clearMonitor()
        #expect(facts.count == 2 && facts.allSatisfy(\.accepted))
        #expect(facts.allSatisfy { $0.values["p"] == 80 && $0.at == 12 })
        #expect(afterIO.allSatisfy(\.self) && model.events.isEmpty)
        #expect(facts[0].id != facts[1].id)
        model.observeMutation = nil
    }
#endif

#if os(macOS)
    @Test @MainActor func inputContextLabelsPriorEvidenceAndNeverLetsOldLayerReleaseEraseNewMismatch() throws {
        let (model, midi) = try neutralConsole()
        midi.onMessages?([.controlChange(channel: 0, number: 25, value: 1)]) // Positive A/E16 evidence.
        #expect(model.session.state.observedLayer == .a)
        midi.onMessages?([.controlChange(channel: 0, number: 52, value: 2)]) // Positive B/E16 evidence.
        let positiveB = try #require(model.events.first { $0.direction == .input && $0.message == .controlChange(channel: 0, number: 52, value: 2) })
        let projectedB = try ConsoleNeutralProjection.input(positiveB, instanceID: "fixture")
        let b = try #require(projectedB)
        #expect(b.context.id.contains("input-facet=b") && b.context.id.contains("prior-device-layer=a"))
        #expect(model.session.state.observedLayer == .b && model.session.state.layerMismatch)
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 0)]) // Old A release does not prove physical A.
        let oldRelease = try #require(model.events.first { $0.direction == .input && $0.message == .controlChange(channel: 0, number: 101, value: 0) })
        let projectedRelease = try ConsoleNeutralProjection.input(oldRelease, instanceID: "fixture")
        let release = try #require(projectedRelease)
        #expect(release.context.id.contains("input-facet=a") && release.context.id.contains("prior-device-layer=b"))
        #expect(model.session.state.observedLayer == .b && model.session.state.layerMismatch)
        let sends = midi.sent.count
        model.recallMotors()
        #expect(midi.sent.count == sends)
    }
#endif
