import Foundation

/// Factory mapping for **Standard MIDI mode only**. Do not apply to Mackie Control mode
/// or to controller presets edited with Behringer's X-TOUCH Editor.
///
/// TX input mappings differ from RX feedback mappings. In particular:
/// - Layer B transmits faders on CC 28...36, but motor feedback is always CC 1...9.
/// - Layer A button 1 transmits Note 16, but its LED receives Note 0.
/// - Encoder rotation CC 10...25, LED-value CC 26...41, ring style CC 10...25.
public struct FactoryStandardMap: Sendable {
    public var transmitChannel: UInt8
    public var globalReceiveChannel: UInt8

    public init(transmitChannel: UInt8 = 0, globalReceiveChannel: UInt8 = 0) throws {
        guard transmitChannel < 16 else { throw CompactError.invalidChannel(transmitChannel) }
        guard globalReceiveChannel < 16 else { throw CompactError.invalidChannel(globalReceiveChannel) }
        self.transmitChannel = transmitChannel
        self.globalReceiveChannel = globalReceiveChannel
    }

    public func decode(_ message: MIDIMessage, layer: CompactLayer) -> CompactInput? {
        switch message {
        case let .controlChange(channel, number, value):
            guard channel == transmitChannel else { return nil }
            let positionBase: UInt8 = layer == .a ? 1 : 28
            let touchBase: UInt8 = layer == .a ? 101 : 111
            let encoderBase: UInt8 = layer == .a ? 10 : 37
            if number >= positionBase, number <= positionBase + 8 {
                return CompactInput(control: .fader(Int(number - positionBase) + 1), layer: layer, value: value)
            }
            if number >= touchBase, number <= touchBase + 8 {
                return CompactInput(control: .faderTouch(Int(number - touchBase) + 1), layer: layer,
                                    value: value, isPressed: value > 0)
            }
            if number >= encoderBase, number <= encoderBase + 15 {
                return CompactInput(control: .encoder(Int(number - encoderBase) + 1), layer: layer, value: value)
            }
            return nil
        case let .noteOn(channel, number, velocity):
            guard channel == transmitChannel else { return nil }
            return decodeNote(number: number, value: velocity, pressed: velocity > 0, layer: layer)
        case let .noteOff(channel, number, velocity):
            guard channel == transmitChannel else { return nil }
            return decodeNote(number: number, value: velocity, pressed: false, layer: layer)
        case .pitchBend, .programChange:
            return nil
        }
    }

    private func decodeNote(number: UInt8, value: UInt8, pressed: Bool, layer: CompactLayer) -> CompactInput? {
        let pushStart: UInt8 = layer == .a ? 0 : 55
        let buttonStart: UInt8 = layer == .a ? 16 : 71
        if number >= pushStart, number <= pushStart + 15 {
            return CompactInput(control: .encoderPush(Int(number - pushStart) + 1), layer: layer,
                                value: value, isPressed: pressed)
        }
        if number >= buttonStart, number <= buttonStart + 38 {
            return CompactInput(control: .button(Int(number - buttonStart) + 1), layer: layer,
                                value: value, isPressed: pressed)
        }
        return nil
    }

    public func selectLayer(_ layer: CompactLayer) -> MIDIMessage {
        .programChange(channel: globalReceiveChannel, number: layer == .a ? 0 : 1)
    }

    public func motorPosition(fader: Int, value: UInt8) throws -> MIDIMessage {
        guard (1...9).contains(fader) else { throw CompactError.invalidIndex("fader", fader) }
        return .controlChange(channel: globalReceiveChannel, number: UInt8(fader), value: value)
    }

    public func encoderRingStyle(encoder: Int, style: RingStyle) throws -> MIDIMessage {
        guard (1...16).contains(encoder) else { throw CompactError.invalidIndex("encoder", encoder) }
        return .controlChange(channel: globalReceiveChannel, number: UInt8(9 + encoder), value: style.rawValue)
    }

    public func encoderRingValue(encoder: Int, display: RingDisplay) throws -> MIDIMessage {
        guard (1...16).contains(encoder) else { throw CompactError.invalidIndex("encoder", encoder) }
        let value: Int
        switch display {
        case .off: value = 0
        case let .position(i):
            guard (1...13).contains(i) else { throw CompactError.invalidDisplayPosition(i) }
            value = i
        case let .blinkingPosition(i):
            guard (1...13).contains(i) else { throw CompactError.invalidDisplayPosition(i) }
            value = i + 13
        case .allOn: value = 27
        case .allBlinking: value = 28
        }
        return .controlChange(channel: globalReceiveChannel, number: UInt8(25 + encoder), value: UInt8(value))
    }

    public func buttonLight(button: Int, light: ButtonLight,
                            style: ButtonLightProtocol) throws -> MIDIMessage {
        guard (1...39).contains(button) else { throw CompactError.invalidIndex("button", button) }
        return .noteOn(channel: globalReceiveChannel, number: UInt8(button - 1),
                       velocity: style.velocity(for: light))
    }
}
