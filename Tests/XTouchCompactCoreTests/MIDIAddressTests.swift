import Testing
@testable import XTouchCompactCore

@Test func inputAddressesCoverEveryFactoryTableRow() throws {
    // Explicit protocol-table fixtures, independent from implementation calculations.
    let rows: [(controls: [CompactControl], a: [Int], b: [Int], type: MIDIAddress.MessageType)] = [
        ((1 ... 9).map(CompactControl.fader), Array(1 ... 9), Array(28 ... 36), .controlChange),
        ((1 ... 9).map(CompactControl.faderTouch), Array(101 ... 109), Array(111 ... 119), .controlChange),
        ((1 ... 16).map(CompactControl.encoder), Array(10 ... 25), Array(37 ... 52), .controlChange),
        ((1 ... 16).map(CompactControl.encoderPush), Array(0 ... 15), Array(55 ... 70), .note),
        ((1 ... 39).map(CompactControl.button), Array(16 ... 54), Array(71 ... 109), .note),
    ]
    for tx: UInt8 in [0, 7, 15] {
        let map = try FactoryStandardMap(transmitChannel: tx, globalReceiveChannel: 3)
        for row in rows {
            for (layer, numbers) in [(CompactLayer.a, row.a), (.b, row.b)] {
                for (control, number) in zip(row.controls, numbers) {
                    let address = try #require(map.inputAddress(for: control, layer: layer))
                    #expect(address.messageType == row.type)
                    #expect(address.channel == tx)
                    #expect(address.number == UInt8(number))
                    let message: MIDIMessage = row.type == .controlChange
                        ? .controlChange(channel: tx, number: address.number, value: 127)
                        : .noteOn(channel: tx, number: address.number, velocity: 127)
                    #expect(map.decode(message, layer: layer)?.control == control)
                    if row.type == .note {
                        #expect(map.decode(.noteOff(channel: tx, number: address.number, velocity: 0),
                                           layer: layer)?.control == control)
                    }
                }
            }
        }
    }
}

@Test func feedbackAddressesCoverFactoryTableAndMatchCommands() throws {
    for rx: UInt8 in [0, 3, 15] {
        let map = try FactoryStandardMap(transmitChannel: 6, globalReceiveChannel: rx)
        for index in 1 ... 9 {
            let address = try #require(map.feedbackAddress(for: .fader(index)))
            #expect(address == MIDIAddress(messageType: .controlChange, channel: rx, number: UInt8(index)))
            #expect(try map.motorPosition(fader: index, value: 42) ==
                .controlChange(channel: address.channel, number: address.number, value: 42))
            #expect(map.feedbackAddress(for: .faderTouch(index)) == nil)
        }
        for (index, number) in zip(1 ... 16, 26 ... 41) {
            let display = try #require(map.feedbackAddress(for: .encoder(index)))
            let style = try #require(map.encoderRingStyleAddress(encoder: index))
            #expect(display == MIDIAddress(messageType: .controlChange, channel: rx, number: UInt8(number)))
            #expect(style == MIDIAddress(messageType: .controlChange, channel: rx, number: UInt8(index + 9)))
            #expect(try map.encoderRingValue(encoder: index, display: .allOn) ==
                .controlChange(channel: display.channel, number: display.number, value: 27))
            #expect(try map.encoderRingStyle(encoder: index, style: .trim) ==
                .controlChange(channel: style.channel, number: style.number, value: 4))
            #expect(map.feedbackAddress(for: .encoderPush(index)) == nil)
        }
        for (index, number) in zip(1 ... 39, 0 ... 38) {
            let address = try #require(map.feedbackAddress(for: .button(index)))
            #expect(address == MIDIAddress(messageType: .note, channel: rx, number: UInt8(number)))
            for variant in ButtonLightProtocol.allCasesForAddressTests {
                #expect(try map.buttonLight(button: index, light: .blink, style: variant) ==
                    .noteOn(channel: address.channel, number: address.number, velocity: variant.velocity(for: .blink)))
            }
        }
    }
}

private extension ButtonLightProtocol {
    static var allCasesForAddressTests: [Self] {
        [.manual, .observed114]
    }
}

@Test func addressAsymmetryFormattingAndInvalidControls() throws {
    let map = try FactoryStandardMap(transmitChannel: 0, globalReceiveChannel: 15)
    #expect(map.inputAddress(for: .fader(1), layer: .b)?.description == "CC ch1 #28")
    #expect(map.feedbackAddress(for: .fader(1))?.description == "CC ch16 #1")
    #expect(map.inputAddress(for: .button(1), layer: .a)?.description == "Note ch1 #16")
    #expect(map.feedbackAddress(for: .button(1))?.description == "Note ch16 #0")
    for index in [Int.min, -1, 0, 40, Int.max] {
        for control in [CompactControl.fader(index), .faderTouch(index), .encoder(index), .encoderPush(index), .button(index)] {
            for layer in CompactLayer.allCases {
                #expect(map.inputAddress(for: control, layer: layer) == nil)
            }
            #expect(map.feedbackAddress(for: control) == nil)
        }
        #expect(map.encoderRingStyleAddress(encoder: index) == nil)
    }
    for control in [CompactControl.fader(10), .faderTouch(10), .encoder(17), .encoderPush(17)] {
        #expect(map.inputAddress(for: control, layer: .a) == nil)
        #expect(map.feedbackAddress(for: control) == nil)
    }
}
