#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @MainActor private func intent<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
        try #require(value, sourceLocation: sourceLocation)
    }

    @Test @MainActor func modeChangesNeverSendMIDIAndSendingNeedsAnExplicitSync() throws {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        let setMode = try intent(model.panelIntents.setMode)
        #expect(model.panelSnapshot.mode == .mock)
        midi.connect()
        midi.sent.removeAll()

        setMode(.hardwareListen)
        #expect(model.panelSnapshot.mode == .hardwareListen)
        #expect(midi.sent.isEmpty)

        // Enabling sending replays nothing: no layer assertion, no LED sync, no motor.
        setMode(.hardwareSend)
        #expect(model.panelSnapshot.mode == .hardwareSend)
        #expect(midi.sent.isEmpty)

        // The explicit sync sends the layer selection and nonmotor feedback, never a motor.
        try intent(model.panelIntents.realignLayer)()
        #expect(midi.sent.contains(.programChange(channel: 0, number: 0)))
        #expect(!midi.sent.contains {
            if case .controlChange(_, 1 ... 9, _) = $0 {
                return true
            }
            return false
        })

        midi.sent.removeAll()
        setMode(.hardwareListen)
        try intent(model.panelIntents.realignLayer)() // Listen-only: suppressed.
        setMode(.mock)
        #expect(model.panelSnapshot.mode == .mock)
        #expect(midi.sent.isEmpty)
    }

    @Test @MainActor func mockToSendPassesThroughListenAndStaysPassiveWithoutAController() throws {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        let setMode = try intent(model.panelIntents.setMode)
        // No controller: asking for send leaves the app listening, never sending.
        setMode(.hardwareSend)
        #expect(model.panelSnapshot.mode == .hardwareListen)
        #expect(midi.sent.isEmpty)
        setMode(.mock)
        midi.connect()
        midi.sent.removeAll()
        // Straight from mock to send with a controller present: still nothing is sent.
        setMode(.hardwareSend)
        #expect(model.panelSnapshot.mode == .hardwareSend)
        #expect(midi.sent.isEmpty)
    }

    @Test @MainActor func inputCheckIsAViewOverListenModeNotAnotherMode() throws {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect()
        try intent(model.panelIntents.setMode)(.hardwareSend)
        try intent(model.panelIntents.beginHardwareObservation)()
        #expect(model.panelSnapshot.hardwareObservation != nil)
        #expect(model.panelSnapshot.mode == .hardwareListen) // Opening the tool forces listen-only.
        try intent(model.panelIntents.endHardwareObservation)()
        #expect(model.panelSnapshot.hardwareObservation == nil)
        #expect(model.panelSnapshot.mode == .hardwareListen) // Closing it does not re-enable sending.
        // Choosing a mode while the tool is open closes it.
        try intent(model.panelIntents.beginHardwareObservation)()
        try intent(model.panelIntents.setMode)(.mock)
        #expect(model.panelSnapshot.hardwareObservation == nil && model.panelSnapshot.mode == .mock)
        try intent(model.panelIntents.beginHardwareObservation)()
        try intent(model.panelIntents.setMode)(.hardwareListen)
        #expect(model.panelSnapshot.hardwareObservation == nil && model.panelSnapshot.mode == .hardwareListen)
    }

    @Test @MainActor func touchedHardwareRejectsLayerSelectionRealignmentAndLightSyncWithoutQueueing() throws {
        for path in 0 ... 2 {
            let midi = FakeMIDIService()
            let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
            midi.connect()
            model.setConsoleMode(.hardwareSend)
            midi.onMessages?([.controlChange(channel: 0, number: 119, value: 127)])
            midi.sent.removeAll()
            if path == 0 {
                model.setLayer(.b)
            }
            if path == 1 {
                model.realignCurrentLayer()
            }
            if path == 2 {
                try intent(model.panelIntents.realignLayer)()
            }
            #expect(midi.sent.isEmpty)
            #expect(model.layer == .a && model.session.state.layer == .a)
            #expect(model.session.state.observedLayer == .b)
            #expect(model.session.state.layerMismatch)
            #expect(model.error as? CompactError == .fadersTouched)
            #expect(!model.panelSnapshot.notifications.isEmpty)
            midi.onMessages?([.controlChange(channel: 0, number: 119, value: 0)])
            #expect(midi.sent.isEmpty) // Release never executes a refused operation.
            if path == 0 {
                model.setLayer(.b)
            } else {
                model.realignCurrentLayer()
            }
            #expect(midi.sent.count == 56)
            #expect(model.layer == (path == 0 ? .b : .a))
        }
    }

    @Test @MainActor func hardwareSafetyLatchBlocksLayerAfterMockTransitionButMockLayerIsUnchanged() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect()
        // While mocking, physical touches are safety-only, independent of mock input touches.
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127)])
        model.setLayer(.b)
        #expect(model.layer == .b && model.mock.layer == .b)
        model.setConsoleMode(.hardwareSend)
        midi.sent.removeAll()
        model.setLayer(.a)
        #expect(midi.sent.isEmpty)
        #expect(model.layer == .b)
        #expect(model.error as? CompactError == .fadersTouched)
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 0)])
        #expect(midi.sent.isEmpty)
        model.setLayer(.a)
        #expect(midi.sent.count == 56)
        #expect(model.layer == .a)
    }
#endif
