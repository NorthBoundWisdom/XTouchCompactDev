#if os(macOS)
import Testing
@testable import XTouchCompactApp
import XTouchCompactCore

@Test @MainActor func inspectorAddressesUseAppliedMappingWithoutSendingMIDI() throws {
    let model = ConsoleModel(startsMIDI: false)
    let addressing = try #require(model.panelIntents.addressing)
    #expect(addressing(.fader(1), .b)?.input == "CC ch1 #28")
    #expect(addressing(.fader(1), .b)?.feedback == "CC ch1 #1")
    // Editing the controls is only a draft until Apply profile is invoked.
    model.transmitChannel = 7
    model.feedbackChannel = 16
    #expect(addressing(.button(1), .a)?.input == "Note ch1 #16")
    model.configure()
    let messages = model.logs
    let snapshot = model.panelSnapshot
    // Even an existing closure reads the current applied session, not stale UI fields.
    #expect(addressing(.fader(1), .b)?.input == "CC ch7 #28")
    #expect(addressing(.fader(1), .b)?.feedback == "CC ch16 #1")
    #expect(addressing(.button(39), .b)?.input == "Note ch7 #109")
    #expect(addressing(.button(39), .b)?.feedback == "Note ch16 #38")
    #expect(addressing(.encoder(16), .b)?.input == "CC ch7 #52")
    #expect(addressing(.encoder(16), .b)?.feedback == "CC ch16 #41 [RingDisplay]; CC ch16 #25 [RingStyle]")
    #expect(addressing(.faderTouch(9), .b)?.input == "CC ch7 #119")
    #expect(addressing(.faderTouch(9), .b)?.feedback == nil)
    #expect(addressing(.encoderPush(16), .b)?.input == "Note ch7 #70")
    #expect(addressing(.encoderPush(16), .b)?.feedback == nil)
    #expect(addressing(.button(40), .a) == nil)
    #expect(model.logs == messages)
    #expect(model.panelSnapshot == snapshot)
}
#endif
