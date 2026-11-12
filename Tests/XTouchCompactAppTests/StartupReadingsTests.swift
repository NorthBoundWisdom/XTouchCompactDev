#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @Test @MainActor func startupRestoresRouteBoundReadingsAsHistoryWithoutRestoringTouchesOrTargets() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let firstMIDI = FakeMIDIService()
        let first = ConsoleModel(startsMIDI: false, midi: firstMIDI, storageRoot: root, isolated: true)
        firstMIDI.connect(); first.useHardware(true)
        firstMIDI.onMessages?([
            .controlChange(channel: 0, number: 28, value: 8),
            .controlChange(channel: 0, number: 37, value: 65),
            .controlChange(channel: 0, number: 111, value: 127),
        ])
        first.flushHardwareValues()
        let midi = FakeMIDIService()
        let restored = ConsoleModel(startsMIDI: false, midi: midi, storageRoot: root, isolated: true)
        midi.connect(); restored.useHardware(true)
        let snapshot = restored.panelSnapshot
        #expect(snapshot.hardwareDisplayLayer == .b)
        #expect(!snapshot.hardwareLayerIsCurrent)
        #expect(snapshot.fader(1)?.panelValue == 8)
        #expect(snapshot.fader(1)?.hardwareReading?.isCurrent == false)
        #expect(snapshot.fader(1)?.observed == nil)
        #expect(snapshot.fader(1)?.isTouched == nil)
        #expect(snapshot.encoder(1)?.panelValue == 65)
        #expect(snapshot.encoder(2)?.panelValue == nil)
        #expect(snapshot.button(1)?.isDown == nil)
        #expect(snapshot.fader(1)?.target == 0)
        #expect(snapshot.layer == .a)
        #expect(snapshot.transmitChannel == 1 && snapshot.feedbackChannel == 1)
        #expect(!restored.session.state.isTouched(1))
        #expect(midi.sent.isEmpty)
    }

    @Test @MainActor func otherLayerPositionsRemainVisibleWhileTouchAloneNeverInventsAPosition() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(); model.useHardware(true)
        #expect(model.panelSnapshot.fader(1)?.panelValue == nil)
        midi.onMessages?([.controlChange(channel: 0, number: 111, value: 127)])
        #expect(model.panelSnapshot.fader(1)?.panelValue == nil)
        #expect(model.panelSnapshot.fader(1)?.isTouched == true)
        #expect(model.panelSnapshot.hardwareDisplayLayer == .b)
        midi.onMessages?([.controlChange(channel: 0, number: 28, value: 8),
                          .controlChange(channel: 0, number: 37, value: 90),
                          .controlChange(channel: 0, number: 111, value: 0)])
        #expect(model.panelSnapshot.fader(1)?.panelValue == 8)
        #expect(model.panelSnapshot.encoder(1)?.panelValue == 90)
        #expect(model.panelSnapshot.fader(1)?.hardwareReading?.isCurrent == true)
        #expect(model.panelSnapshot.hardwareLayerIsCurrent)
        #expect(model.layer == .a && model.bank.faders[0] == 0 && model.bank.encoders[0] == 0)
        #expect(model.session.state.layerMismatch)
        model.enableHardwareWriteback(); model.faderChanged(2, value: 80)
        #expect(midi.sent.isEmpty) // Displaying B does not authorize motors while host is A.
    }

    @Test @MainActor func readingFreshnessResetsOnReconnectAndDoesNotCrossInputOrTXChannel() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(); model.useHardware(true)
        midi.onMessages?([.controlChange(channel: 0, number: 1, value: 35)])
        midi.onConnection?(CompactMIDIConnection())
        #expect(model.panelSnapshot.fader(1)?.panelValue == nil)
        midi.connect()
        #expect(model.panelSnapshot.fader(1)?.panelValue == 35)
        #expect(model.panelSnapshot.fader(1)?.hardwareReading?.isCurrent == false)
        #expect(model.panelSnapshot.fader(1)?.observed == nil)
        let other = CompactMIDIEndpoint(id: 2, name: "Another device")
        midi.onConnection?(CompactMIDIConnection(connectedInput: other, connectedOutput: other))
        #expect(model.panelSnapshot.fader(1)?.panelValue == nil)
        #expect(model.panelSnapshot.fader(1)?.observed == nil)
        midi.connect()
        model.transmitChannel = 4; model.configure()
        #expect(model.panelSnapshot.fader(1)?.panelValue == nil)
        midi.onMessages?([.controlChange(channel: 0, number: 1, value: 99)])
        #expect(model.panelSnapshot.fader(1)?.panelValue == nil)
        midi.onMessages?([.controlChange(channel: 3, number: 1, value: 45)])
        #expect(model.panelSnapshot.fader(1)?.panelValue == 45)
        #expect(midi.sent.isEmpty)
    }

    @Test @MainActor func softwareCommandsNeverBecomeCachedHardwareValues() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(); model.useHardware(true)
        midi.onMessages?([.controlChange(channel: 0, number: 1, value: 20)])
        model.enableHardwareWriteback()
        model.faderChanged(1, value: 60)
        model.encoderChanged(1, value: 80)
        #expect(midi.sent.contains(.controlChange(channel: 0, number: 1, value: 60)))
        #expect(model.panelSnapshot.fader(1)?.target == 60)
        #expect(model.panelSnapshot.fader(1)?.panelValue == 20)
        #expect(model.panelSnapshot.fader(1)?.hardwareReading?.isCurrent == false)
        #expect(model.hardwareValueCache?.faders[1]?.value == 20)
        #expect(model.panelSnapshot.encoder(1)?.panelValue == nil)
        #expect(model.hardwareValueCache?.encoders[.a]?[1] == nil)
        midi.onMessages?([.controlChange(channel: 0, number: 1, value: 30)])
        #expect(model.panelSnapshot.fader(1)?.hardwareReading?.isCurrent == true)
        midi.fails = true
        model.faderChanged(1, value: 70)
        #expect(model.panelSnapshot.fader(1)?.hardwareReading?.isCurrent == false)
        #expect(model.panelSnapshot.fader(1)?.panelValue == 30)
    }

    @Test @MainActor func physicalPressesRemainIndependentOfTheActiveMockSession() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect()
        midi.onMessages?([.noteOn(channel: 0, number: 0, velocity: 127),
                          .noteOn(channel: 0, number: 16, velocity: 127)])
        #expect(model.panelSnapshot.encoder(1)?.isPushed == false)
        model.useHardware(true)
        #expect(model.panelSnapshot.encoder(1)?.isPushed == true)
        #expect(model.panelSnapshot.button(1)?.isDown == true)
        midi.onConnection?(CompactMIDIConnection())
        midi.connect()
        #expect(model.panelSnapshot.encoder(1)?.isPushed == nil)
        #expect(model.panelSnapshot.button(1)?.isDown == nil)
        #expect(midi.sent.isEmpty)
    }
#endif
