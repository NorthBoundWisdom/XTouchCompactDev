#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @Test @MainActor func observationMirrorsPhysicalFactsWithoutSoftwareWritesOrAgentActions() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        model.faderChanged(1, value: 110)
        midi.connect()
        model.panelIntents.beginHardwareObservation?()
        let initial = model.panelSnapshot
        #expect(initial.hardwareObservation?.messageCount == 0)
        #expect(initial.fader(1)?.target == 110)
        #expect(initial.fader(1)?.observed == nil)
        #expect(initial.fader(1)?.isTouched == nil)
        #expect(initial.encoder(1)?.observedValue == nil)
        #expect(initial.button(1)?.isDown == nil)
        let parameters = model.panelSnapshot.parameterValues

        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127)])
        #expect(model.panelSnapshot.fader(1)?.isTouched == true)
        #expect(model.panelSnapshot.hardwareObservation?.latest?.panelControl == .fader(1))
        midi.onMessages?([.controlChange(channel: 0, number: 1, value: 64)])
        #expect(model.panelSnapshot.fader(1)?.observed == 64)
        #expect(model.panelSnapshot.fader(1)?.capPosition == 64)
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 0)])
        #expect(model.panelSnapshot.fader(1)?.isTouched == false)
        #expect(model.panelSnapshot.fader(1)?.capPosition == 64) // Stays physical after release, not target 110.
        midi.onMessages?([.noteOn(channel: 0, number: 16, velocity: 127),
                          .noteOff(channel: 0, number: 16, velocity: 0)])
        #expect(model.panelSnapshot.button(1)?.isDown == false)
        #expect(model.agents.slots.allSatisfy { $0.phase == .idle })
        #expect(model.panelSnapshot.parameterValues == parameters)
        #expect(model.session.bank(.a).faders[0] == 110)
        #expect(midi.sent.isEmpty)
        #expect(model.panelSnapshot.hardwareObservation?.messageCount == 5)
    }

    @Test @MainActor func observationCoversEveryControlOnBothLayersWithoutSelectingHostLayer() throws {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect(); model.beginHardwareObservation()
        var device = try MockXTouchCompact(map: FactoryStandardMap(), lightProtocol: .manual)
        for layer in CompactLayer.allCases {
            device.selectPhysicalLayer(layer)
            for i in 1 ... 9 {
                try midi.onMessages?(device.touchFader(i, isTouched: true))
                try midi.onMessages?(device.moveFader(i, value: UInt8(i * 10)))
                try midi.onMessages?(device.touchFader(i, isTouched: false))
            }
            for i in 1 ... 16 {
                try midi.onMessages?(device.turnEncoder(i, value: UInt8(i + (layer == .a ? 0 : 50))))
                try midi.onMessages?(device.pushEncoder(i, isDown: true))
                #expect(model.panelSnapshot.encoder(i)?.isPushed == true)
                try midi.onMessages?(device.pushEncoder(i, isDown: false))
            }
            for i in 1 ... 39 {
                try midi.onMessages?(device.pressButton(i, isDown: true))
                #expect(model.panelSnapshot.button(i)?.isDown == true)
                try midi.onMessages?(device.pressButton(i, isDown: false))
            }
        }
        let snapshot = model.panelSnapshot
        let observation = try #require(snapshot.hardwareObservation)
        #expect(observation.seenControls.count == CompactGeometry.totalInputActions)
        #expect(observation.inputLayer == .b)
        #expect(snapshot.layer == .a) // Physical-layer evidence never selects the host bank.
        #expect(snapshot.fader(9)?.observed == 90)
        #expect(snapshot.encoder(16)?.observedValue == 66)
        #expect(observation.encoderValues[.a]?[16] == 16)
        #expect(observation.encoderValues[.b]?[16] == 66)
        #expect(observation.recent.count == 12)
        #expect(model.events.count == 120)
        #expect(midi.sent.isEmpty)
    }

    @Test @MainActor func observationLocksOutputAcrossWritesReconnectAndResetButKeepsTouchSafety() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect(); model.setListenOnly(false); model.useHardware(true)
        midi.sent.removeAll()
        model.beginHardwareObservation()
        model.setListenOnly(false)
        #expect(model.listenOnly)
        model.panelIntents.setFader(1, 100)
        model.recallMotors()
        midi.onMessages?([.controlChange(channel: 0, number: 111, value: 127)])
        #expect(model.session.state.isTouched(1))
        #expect(model.session.state.layerMismatch)
        model.resetHardwareObservation()
        #expect(model.panelSnapshot.hardwareObservation?.messageCount == 0)
        #expect(model.panelSnapshot.fader(1)?.isTouched == nil)
        #expect(model.session.state.isTouched(1)) // Clearing the UI never clears safety ownership.
        midi.onConnection?(CompactMIDIConnection()); midi.connect()
        #expect(midi.sent.isEmpty)
        model.panelIntents.endHardwareObservation?()
        #expect(model.panelSnapshot.hardwareObservation == nil)
        #expect(model.listenOnly)
        #expect(model.session.state.isTouched(1))
        #expect(model.session.state.layerMismatch)
        #expect(midi.sent.isEmpty)
    }

    @Test @MainActor func observationRetainsWrongChannelAndUnknownInputWithoutRewritingProfile() throws {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect(); model.beginHardwareObservation()
        midi.onMessages?([.controlChange(channel: 4, number: 101, value: 127)])
        let latest = try #require(model.panelSnapshot.hardwareObservation?.latest)
        #expect(latest.channel == 5)
        #expect(!latest.matchesConfiguredChannel)
        #expect(latest.input == nil)
        #expect(model.panelSnapshot.fader(1)?.isTouched == nil)
        #expect(model.transmitChannel == 1)
        #expect(model.feedbackChannel == 1)
        midi.onMessages?([.pitchBend(channel: 0, value: 8192)])
        #expect(model.panelSnapshot.hardwareObservation?.latest?.input == nil)
        #expect(model.panelSnapshot.hardwareObservation?.latest?.message == .pitchBend(channel: 0, value: 8192))
        #expect(model.panelSnapshot.hardwareObservation?.messageCount == 2)
        #expect(midi.sent.isEmpty)
    }

    @Test @MainActor func observerDoesNotTreatSoftwareOrMockValuesAsPhysicalObservations() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect(); model.beginHardwareObservation()
        model.faderChanged(1, value: 99)
        model.encoderChanged(1, value: 88)
        #expect(model.panelSnapshot.hardwareObservation?.messageCount == 0)
        #expect(model.panelSnapshot.fader(1)?.observed == nil)
        #expect(model.panelSnapshot.encoder(1)?.observedValue == nil)
        #expect(midi.sent.isEmpty)
        model.useHardware(false)
        model.moveFader(1, value: 33)
        model.beginHardwareObservation()
        #expect(model.panelSnapshot.hardwareObservation?.messageCount == 0)
        #expect(model.panelSnapshot.fader(1)?.observed == nil)
    }

    @Test @MainActor func observationCaptureRecordsPhysicalTouchReleaseAndNoOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect(); model.beginHardwareObservation(); model.startCapture(root.appendingPathComponent("input.jsonl"))
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127),
                          .controlChange(channel: 0, number: 1, value: 42),
                          .controlChange(channel: 0, number: 101, value: 0)])
        model.stopCapture()
        let rows = try String(contentsOf: root.appendingPathComponent("input.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        #expect(rows.last?["kind"] as? String == "capture-end")
        #expect(rows.filter { $0["direction"] as? String == "IN" }.count == 3)
        #expect(!rows.contains { $0["direction"] as? String == "OUT" })
        #expect(midi.sent.isEmpty)
    }

    @Test @MainActor func observationAdapterPreservesUnknownsAndConvertsOnlyDisplayChannels() throws {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        model.transmitChannel = 5; model.feedbackChannel = 12; model.configure()
        midi.connect(); model.beginHardwareObservation()
        midi.onMessages?([.controlChange(channel: 4, number: 101, value: 127),
                          .controlChange(channel: 4, number: 37, value: 99)])
        let snapshot = model.panelSnapshot
        let observation = try #require(snapshot.hardwareObservation)
        #expect(model.hardwareObserver.recent.first?.channel == 4)
        #expect(observation.latest?.channel == 5)
        #expect(snapshot.feedbackChannel == 12)
        #expect(observation.touchedFaders == [1])
        #expect(observation.coverage.map(\.count) == [0, 1, 1, 0, 0])
        #expect(observation.coverage.map(\.total) == [9, 9, 16, 16, 39])
        #expect(snapshot.fader(1)?.observed == nil)
        #expect(snapshot.fader(1)?.isTouched == true)
        #expect(snapshot.fader(2)?.isTouched == nil)
        #expect(snapshot.encoder(1)?.observedValue == 99)
        #expect(snapshot.encoder(1)?.isPushed == nil)
        #expect(snapshot.button(1)?.isDown == nil)
        #expect(snapshot.layer == .a)
        #expect(observation.inputLayer == .b)
        midi.onMessages?([.controlChange(channel: 4, number: 10, value: 12)])
        #expect(model.panelSnapshot.encoder(1)?.observedValue == 12)
        #expect(model.panelSnapshot.hardwareObservation?.encoderValues[.b]?[1] == 99)
        model.endHardwareObservation()
        #expect(model.panelSnapshot.encoder(1)?.observedValue == nil)
        #expect(model.panelSnapshot.encoder(1)?.observesInput == false)
        #expect(model.panelSnapshot.fader(1)?.isTouched == true)
        #expect(midi.sent.isEmpty)
    }
#endif
