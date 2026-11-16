#if os(macOS)
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @Test @MainActor func independentPanelFeedbackReachesTheVisibleRingAndFreshIndicator() throws {
        let model = ConsoleModel(startsMIDI: false, midi: FakeMIDIService(), isolated: true)
        let parameters = model.panelSnapshot.parameterValues
        let input = model.bank.encoders[1]
        model.apply { session in
            try session.setDisplayRing(2, value: 127) + session.setDisplayButton(8, light: .on)
        }
        let encoder = try #require(model.panelSnapshot.encoder(2))
        #expect(encoder.ring == .position(13))
        let visible = RingLEDs.lit(encoder.ring, style: encoder.style, localAppearance: encoder.localRingAppearance)
        #expect(visible.segments == [13])
        #expect(!visible.isBlinking)
        #expect(model.panelSnapshot.button(8)?.light == .on)
        #expect(model.bank.encoders[1] == input)
        #expect(model.panelSnapshot.parameterValues == parameters)
        model.apply { session in
            try session.setDisplayRing(2, value: 0) + session.setDisplayButton(8, light: .off)
        }
        let rest = try #require(model.panelSnapshot.encoder(2))
        #expect(RingLEDs.lit(rest.ring, style: rest.style, localAppearance: rest.localRingAppearance).segments == [1])
        #expect(model.panelSnapshot.button(8)?.light == .off)
    }

    @Test @MainActor func operatorInputAndLayerRedrawRestoreTheOriginalCalibratedAppearance() throws {
        let model = ConsoleModel(startsMIDI: false, midi: FakeMIDIService(), isolated: true)
        model.apply { try $0.setDisplayRing(12, value: 127) }
        #expect(model.session.hasDisplayOnlyRingIntent(12))
        #expect(model.panelSnapshot.encoder(12)?.localRingAppearance == nil)
        model.panelIntents.setEncoder(12, 64)
        #expect(!model.session.hasDisplayOnlyRingIntent(12))
        #expect(model.panelSnapshot.encoder(12)?.localRingAppearance == .bipolar(value: 64))
        model.apply { try $0.setDisplayRing(12, value: 127) }
        #expect(model.session.hasDisplayOnlyRingIntent(12))
        let selectLayer = try #require(model.panelIntents.selectLayer)
        selectLayer(.b)
        #expect(!model.session.hasDisplayOnlyRingIntent(12))
        #expect(model.panelSnapshot.encoder(12)?.localRingAppearance == .bipolar(value: 0))
    }
#endif
