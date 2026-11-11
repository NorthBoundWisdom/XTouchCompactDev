import Testing
@testable import XTouchCompactCore

@Test func factoryMapAAndB() throws {
    let map = try FactoryStandardMap()
    #expect(map.decode(.controlChange(channel: 0, number: 1, value: 64), layer: .a)?.control == .fader(1))
    #expect(map.decode(.controlChange(channel: 0, number: 28, value: 64), layer: .b)?.control == .fader(1))
    #expect(map.decode(.controlChange(channel: 0, number: 101, value: 127), layer: .a)?.control == .faderTouch(1))
    #expect(map.decode(.controlChange(channel: 0, number: 111, value: 127), layer: .b)?.control == .faderTouch(1))
    #expect(map.decode(.controlChange(channel: 0, number: 10, value: 32), layer: .a)?.control == .encoder(1))
    #expect(map.decode(.controlChange(channel: 0, number: 37, value: 32), layer: .b)?.control == .encoder(1))
    #expect(map.decode(.noteOn(channel: 0, number: 0, velocity: 127), layer: .a)?.control == .encoderPush(1))
    #expect(map.decode(.noteOn(channel: 0, number: 55, velocity: 127), layer: .b)?.control == .encoderPush(1))
    #expect(map.decode(.noteOn(channel: 0, number: 16, velocity: 127), layer: .a)?.control == .button(1))
    #expect(map.decode(.noteOn(channel: 0, number: 71, velocity: 127), layer: .b)?.control == .button(1))
    #expect(map.decode(.noteOff(channel: 0, number: 54, velocity: 0), layer: .a)?.control == .button(39))
    #expect(map.decode(.noteOn(channel: 0, number: 109, velocity: 127), layer: .b)?.control == .button(39))
    #expect(map.decode(.noteOn(channel: 1, number: 16, velocity: 127), layer: .a) == nil)
}

@Test func inputFeedbackAddressAsymmetry() throws {
    let map = try FactoryStandardMap(transmitChannel: 0, globalReceiveChannel: 3)
    #expect(map.decode(.controlChange(channel: 0, number: 28, value: 48), layer: .b)?.control == .fader(1))
    #expect(try map.motorPosition(fader: 1, value: 48) == .controlChange(channel: 3, number: 1, value: 48))
    #expect(try map.encoderRingStyle(encoder: 1, style: .pan) == .controlChange(channel: 3, number: 10, value: 1))
    #expect(try map.encoderRingValue(encoder: 1, display: .position(13)) == .controlChange(channel: 3, number: 26, value: 13))
    #expect(try map.encoderRingValue(encoder: 16, display: .blinkingPosition(8)) == .controlChange(channel: 3, number: 41, value: 21))
    #expect(try map.buttonLight(button: 1, light: .on, style: .observed114) == .noteOn(channel: 3, number: 0, velocity: 2))
    #expect(try map.buttonLight(button: 1, light: .on, style: .manual) == .noteOn(channel: 3, number: 0, velocity: 1))
    #expect(map.selectLayer(.b) == .programChange(channel: 3, number: 1))
}

@Test func mapRejectsInvalidAddresses() throws {
    #expect(throws: CompactError.self) { _ = try FactoryStandardMap(transmitChannel: 16) }
    let map = try FactoryStandardMap()
    #expect(throws: CompactError.self) { _ = try map.motorPosition(fader: 10, value: 80) }
    #expect(throws: CompactError.self) { _ = try map.encoderRingValue(encoder: 3, display: .position(14)) }
    #expect(throws: CompactError.self) { _ = try map.buttonLight(button: 40, light: .off, style: .manual) }
}

@Test func midi1Bytes() {
    #expect(MIDIMessage.programChange(channel: 0, number: 1).midi1Bytes == [0xC0, 1])
    #expect(MIDIMessage.pitchBend(channel: 0, value: 16383).midi1Bytes == [0xE0, 0x7F, 0x7F])
    #expect(MIDIMessage.noteOn(channel: 0, number: 3, velocity: 2).midi1Bytes == [0x90, 3, 2])
}
