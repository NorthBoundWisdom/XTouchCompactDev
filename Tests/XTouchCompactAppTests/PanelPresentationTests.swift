#if os(macOS)
import XCTest
import XTouchCompactCore
import XTouchCompactLocalization
@testable import XTouchCompactApp

final class PanelPresentationTests: XCTestCase {
    func testLayoutPlacesEveryButtonAndEncoderExactlyOnce() {
        var buttons: [Int] = []
        for strip in 1 ... PanelLayout.stripCount {
            buttons += PanelLayout.stripButtons(strip: strip)
            buttons.append(PanelLayout.selectButton(strip: strip))
        }
        buttons.append(PanelLayout.masterButton)
        buttons += PanelLayout.transport.map(\.button)
        XCTAssertEqual(buttons.sorted(), Array(1 ... CompactGeometry.buttonCount))
        XCTAssertEqual(PanelLayout.topEncoders + PanelLayout.sideEncoders, Array(1 ... CompactGeometry.encoderCount))
        XCTAssertEqual(PanelLayout.masterFader, CompactGeometry.faderCount)
        // Transport buttons are the group the state model invalidates together.
        XCTAssertEqual(PanelLayout.transport.map(\.button), Array(34 ... 39))
    }

    func testButtonNamesDescribeTheirPanelArea() {
        XCTAssertEqual(PanelLayout.buttonName(1), "按键 行1 #1")
        XCTAssertEqual(PanelLayout.buttonName(16), "按键 行2 #8")
        XCTAssertEqual(PanelLayout.buttonName(24), "按键 行3 #8")
        XCTAssertEqual(PanelLayout.buttonName(25), "推子下按键 #1")
        XCTAssertEqual(PanelLayout.buttonName(33), "主推子按键")
        XCTAssertEqual(PanelLayout.buttonName(39), "走带 · 播放")
        XCTAssertEqual(CompactControl.fader(9).localizedName, "主推子")
        XCTAssertEqual(CompactControl.encoderPush(12).shortName, "E12⏎")
    }

    func testRingSegmentsFollowDisplayAndStyle() {
        XCTAssertEqual(RingLEDs.lit(.off, style: .fan), .init(segments: [], isBlinking: false))
        XCTAssertEqual(RingLEDs.lit(.allOn, style: nil).segments.count, 13)
        XCTAssertTrue(RingLEDs.lit(.allBlinking, style: nil).isBlinking)
        XCTAssertEqual(RingLEDs.lit(.position(4), style: nil).segments, [4])
        XCTAssertEqual(RingLEDs.lit(.position(4), style: .single).segments, [4])
        XCTAssertEqual(RingLEDs.lit(.blinkingPosition(4), style: .single), .init(segments: [4], isBlinking: true))
        XCTAssertEqual(RingLEDs.lit(.position(4), style: .fan).segments, [1, 2, 3, 4])
        XCTAssertEqual(RingLEDs.lit(.position(4), style: .pan).segments, [4, 5, 6, 7])
        XCTAssertEqual(RingLEDs.lit(.position(10), style: .pan).segments, [7, 8, 9, 10])
        XCTAssertEqual(RingLEDs.lit(.position(7), style: .pan).segments, [7])
        XCTAssertEqual(RingLEDs.lit(.position(1), style: .spread).segments, [7])
        XCTAssertEqual(RingLEDs.lit(.position(13), style: .spread).segments, Set(1 ... 13))
        // Out-of-range positions are clamped for drawing; the core rejects them when encoding.
        XCTAssertEqual(RingLEDs.lit(.position(99), style: nil).segments, [13])
        XCTAssertEqual(RingLEDs.lit(.position(-3), style: .fan).segments, [1])
    }

    func testFaderTravelMapsSlotEndsToFullRange() {
        XCTAssertEqual(FaderTravel.value(at: 15, length: 196, cap: 30), 127)
        XCTAssertEqual(FaderTravel.value(at: 181, length: 196, cap: 30), 0)
        XCTAssertEqual(FaderTravel.value(at: -50, length: 196, cap: 30), 127)
        XCTAssertEqual(FaderTravel.value(at: 500, length: 196, cap: 30), 0)
        XCTAssertEqual(FaderTravel.value(at: 98, length: 196, cap: 30), 64)
        XCTAssertEqual(FaderTravel.value(at: 10, length: 20, cap: 30), 0)
        XCTAssertEqual(FaderTravel.fraction(for: 127), 1)
        XCTAssertEqual(FaderTravel.fraction(for: 0), 0)
    }

    func testConsoleLayoutKeepsPanelWithinTheAvailableWidth() {
        let minimum = ConsoleLayout(available: CGSize(width: 900, height: 650))
        XCTAssertFalse(minimum.isSideBySide)
        XCTAssertEqual(minimum.scale, 1)
        for size in [CGSize(width: 1_345, height: 975), CGSize(width: 2_400, height: 1_500)] {
            let layout = ConsoleLayout(available: size)
            XCTAssertTrue(layout.isSideBySide)
            XCTAssertLessThanOrEqual(layout.scale, PanelMetrics.scaleRange.upperBound)
            XCTAssertGreaterThanOrEqual(layout.workspaceWidth, ConsoleLayout.minWorkspace)
            XCTAssertLessThanOrEqual(layout.contentWidth, size.width - ConsoleLayout.padding * 2 + 0.5)
        }
    }

    @MainActor
    func testAdapterReflectsSessionStateAndLeavesUnreportedFieldsNil() {
        let model = ConsoleModel(startsMIDI: false)
        let intents = model.panelIntents
        intents.setFader(3, 100)
        intents.turnEncoder(12, 5)
        intents.turnEncoder(12, -200)
        intents.setEncoder(2, 127)
        intents.pressButton(39)

        let snapshot = model.panelSnapshot
        XCTAssertTrue(snapshot.isMock)
        XCTAssertEqual(snapshot.layer, .a)
        XCTAssertEqual(snapshot.faders.count, 9)
        XCTAssertEqual(snapshot.encoders.count, 16)
        XCTAssertEqual(snapshot.buttons.count, 39)
        XCTAssertEqual(snapshot.fader(3)?.target, 100)
        XCTAssertEqual(snapshot.encoder(12)?.value, 0)
        XCTAssertEqual(snapshot.encoder(2)?.ring, .position(13))
        XCTAssertEqual(snapshot.button(39)?.light, .on)
        XCTAssertEqual(snapshot.button(1)?.light, .off)
        // Not reported by the backend yet: the UI must hide these, not guess them.
        XCTAssertNil(snapshot.fader(3)?.observed)
        XCTAssertEqual(snapshot.fader(3)?.isTouched, false)
        XCTAssertEqual(snapshot.fader(3)?.isMotorPending, false)
        XCTAssertNil(snapshot.encoder(2)?.style)
        XCTAssertEqual(snapshot.encoder(2)?.isPushed, false)
        XCTAssertEqual(snapshot.button(39)?.isDown, true)
        XCTAssertNil(snapshot.fader(3)?.label)
        XCTAssertNil(snapshot.fader(3)?.detail)
        XCTAssertNotNil(intents.touchFader)
        XCTAssertNotNil(intents.pushEncoder)
        XCTAssertNotNil(intents.releaseButton)
        XCTAssertNil(intents.addressing)
    }

    @MainActor
    func testMockPanelGesturesTraverseMIDIWhileInspectorWritesDriveFeedback() {
        let model = ConsoleModel(startsMIDI: false)
        let intents = model.panelIntents
        intents.touchFader?(1, true)
        intents.moveFader(1, 31)
        intents.setFader(1, 106)
        XCTAssertEqual(model.bank.faders[0], 106)
        XCTAssertEqual(model.mock.faders[0], 31)
        XCTAssertEqual(model.panelSnapshot.fader(1)?.target, 106)
        XCTAssertEqual(model.panelSnapshot.fader(1)?.observed, 31)
        XCTAssertEqual(model.panelSnapshot.fader(1)?.isTouched, true)
        XCTAssertEqual(model.panelSnapshot.fader(1)?.isMotorPending, true)
        XCTAssertEqual(model.panelSnapshot.fader(1)?.capPosition, 31)
        XCTAssertFalse(model.logs.map { Localizer(language: .english).text($0) }.contains("OUT CC ch1 #1=106 [MOCK]"))
        intents.touchFader?(1, false)
        XCTAssertEqual(model.mock.faders[0], 106)
        XCTAssertEqual(model.panelSnapshot.fader(1)?.isTouched, false)
        XCTAssertEqual(model.panelSnapshot.fader(1)?.isMotorPending, false)
        XCTAssertEqual(model.panelSnapshot.fader(1)?.observed, 31) // RX is not a TX observation.
        XCTAssertEqual(model.panelSnapshot.fader(1)?.capPosition, 106)
        XCTAssertEqual(model.logs.map { Localizer(language: .english).text($0) }.filter { $0 == "OUT CC ch1 #1=106 [MOCK]" }.count, 1)
        XCTAssertEqual(model.mock.ignoredMotorCommands, 0)
        // Consuming a motor command must not fake a position observation.
        XCTAssertEqual(model.logs.map { Localizer(language: .english).text($0) }.filter { $0 == "IN CC ch1 #1=106 [MOCK]" }.count, 0)

        intents.pushEncoder?(2, true)
        XCTAssertTrue(model.mock.pushedEncoders.contains(2))
        XCTAssertEqual(model.panelSnapshot.encoder(2)?.isPushed, true)
        intents.pushEncoder?(2, false)
        XCTAssertFalse(model.mock.pushedEncoders.contains(2))
        XCTAssertEqual(model.panelSnapshot.encoder(2)?.isPushed, false)
        intents.pressButton(1)
        XCTAssertEqual(model.panelSnapshot.button(1)?.isDown, true)
        intents.releaseButton?(1)
        XCTAssertEqual(model.panelSnapshot.button(1)?.isDown, false)
        XCTAssertTrue(model.bank.buttons[0])
        XCTAssertEqual(model.mock.buttons[0], .on)
        XCTAssertTrue(model.logs.map { Localizer(language: .english).text($0) }.contains("IN Note On ch1 #16=127 [MOCK]"))
        XCTAssertTrue(model.logs.map { Localizer(language: .english).text($0) }.contains("IN Note Off ch1 #16=0 [MOCK]"))
        XCTAssertNil(model.error)
    }

    @MainActor
    func testLayerChangeCancelsOldDeferredMotorWithoutMovingPhysicalFader() {
        let model = ConsoleModel(startsMIDI: false)
        let intents = model.panelIntents
        intents.touchFader?(1, true)
        intents.moveFader(1, 31)
        intents.setFader(1, 106)
        model.setLayer(.b)
        XCTAssertEqual(model.mock.layer, .b)
        XCTAssertEqual(model.panelSnapshot.fader(1)?.isTouched, true)
        XCTAssertEqual(model.panelSnapshot.fader(1)?.isMotorPending, false)
        XCTAssertEqual(model.panelSnapshot.fader(1)?.capPosition, 31)
        intents.touchFader?(1, false)
        XCTAssertEqual(model.mock.faders[0], 31)
        XCTAssertEqual(model.bank.faders[0], 0)
        XCTAssertEqual(model.session.bank(.a).faders[0], 106)
        model.recallMotors()
        XCTAssertEqual(model.mock.faders[0], 0)
        XCTAssertEqual(model.mock.ignoredMotorCommands, 0)
    }

    @MainActor
    func testDisconnectedHardwareConfigurationStillPresentsAllControls() {
        let model = ConsoleModel(startsMIDI: false)
        model.useHardware(true)
        XCTAssertNotNil(model.error) // No real service or endpoints in this test.
        model.configure()
        XCTAssertEqual(model.panelSnapshot.faders.count, 9)
        XCTAssertEqual(model.panelSnapshot.encoders.count, 16)
        XCTAssertEqual(model.panelSnapshot.buttons.count, 39)
        XCTAssertNil(model.panelIntents.touchFader)
        XCTAssertNil(model.panelIntents.pushEncoder)
        XCTAssertNil(model.panelIntents.releaseButton)
    }
}
#endif
