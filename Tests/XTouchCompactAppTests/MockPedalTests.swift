#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @MainActor private func intent<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
        try #require(value, sourceLocation: sourceLocation)
    }

    @Test @MainActor func mockPedalsTransmitOnTheActiveLayerAndDriveBoundParameters() throws {
        let time = Date(timeIntervalSince1970: 100)
        let model = ConsoleModel(startsMIDI: false, now: { time }, isolated: true)
        var config = SurfaceConfiguration.neutral
        config.assignments.append(.init(control: .expression, layer: .a, action: .parameter("a.Encoder.5")))
        config.assignments.append(.init(control: .footswitch, layer: .a, action: .set("a.Encoder.6", 100)))
        model.applyConfiguration(config)
        #expect(model.panelSnapshot.mockPedals == MockPedalPresentation(expression: nil, footswitchDown: false))
        #expect(model.panelSnapshot.surfaceStatus.footSwitch == .off)
        #expect(model.panelSnapshot.surfaceStatus.footExpression == .off)

        try intent(model.panelIntents.moveExpression)(64)
        #expect(model.session.parameters.values["a.Encoder.5"] == 64)
        #expect(model.events.contains { $0.direction == .input && $0.message == .controlChange(channel: 0, number: 26, value: 64) })
        #expect(model.panelSnapshot.mockPedals?.expression == 64)
        #expect(model.panelSnapshot.surfaceStatus.footExpression == .pulse(until: time.addingTimeInterval(0.2)))

        try intent(model.panelIntents.pressFootswitch)(true)
        #expect(model.panelSnapshot.surfaceStatus.footSwitch == .on)
        #expect(model.session.parameters.values["a.Encoder.6"] == 100)
        try intent(model.panelIntents.pressFootswitch)(false)
        #expect(model.panelSnapshot.surfaceStatus.footSwitch == .off)
        #expect(model.events.contains { $0.message == .controlChange(channel: 0, number: 27, value: 0) })

        // Layer-B addressing (CC 63 / 64) is covered by Core mockPedalsUseTXChannelAndPhysicalLayer.
        // No pedal reaches a motor.
        #expect(!model.events.contains {
            guard $0.direction == .output, case .controlChange(_, 1 ... 9, _)? = $0.message else { return false }
            return true
        })
    }

    @Test @MainActor func hardwareModeHasNoSimulatedPedals() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect()
        model.useHardware(true)
        #expect(model.panelSnapshot.mockPedals == nil)
        #expect(model.panelIntents.moveExpression == nil && model.panelIntents.pressFootswitch == nil)
        #expect(model.panelSnapshot.surfaceStatus.footSwitch == nil) // Physical FOOT LEDs stay unknown.
        model.moveExpression(50)
        #expect(midi.sent.isEmpty || !midi.sent.contains(.controlChange(channel: 0, number: 26, value: 50)))
    }
#endif
