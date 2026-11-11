/// A channel/number address, not a physical identity or an acknowledgement.
/// Note addresses cover both Note On and Note Off; channels are zero-based.
public struct MIDIAddress: Equatable, Hashable, Sendable, CustomStringConvertible {
    public enum MessageType: String, Sendable { case controlChange = "CC", note = "Note" }

    public let messageType: MessageType
    public let channel: UInt8
    public let number: UInt8

    public var description: String {
        "\(messageType.rawValue) ch\(Int(channel) + 1) #\(number)"
    }
}

public extension FactoryStandardMap {
    /// Factory device TX address on the specified layer. Invalid physical IDs return nil.
    func inputAddress(for control: CompactControl, layer: CompactLayer) -> MIDIAddress? {
        guard transmitChannel < 16 else { return nil }
        let type: MIDIAddress.MessageType
        let number: Int
        switch control {
        case let .fader(index):
            guard (1 ... 9).contains(index) else { return nil }
            type = .controlChange; number = (layer == .a ? 1 : 28) + index - 1
        case let .faderTouch(index):
            guard (1 ... 9).contains(index) else { return nil }
            type = .controlChange; number = (layer == .a ? 101 : 111) + index - 1
        case let .encoder(index):
            guard (1 ... 16).contains(index) else { return nil }
            type = .controlChange; number = (layer == .a ? 10 : 37) + index - 1
        case let .encoderPush(index):
            guard (1 ... 16).contains(index) else { return nil }
            type = .note; number = (layer == .a ? 0 : 55) + index - 1
        case let .button(index):
            guard (1 ... 39).contains(index) else { return nil }
            type = .note; number = (layer == .a ? 16 : 71) + index - 1
        }
        return MIDIAddress(messageType: type, channel: transmitChannel, number: UInt8(number))
    }

    /// Factory Global RX address, independent of layer. Encoder feedback means ring display;
    /// ring style is a separate address. Touch and encoder push have no feedback of their own.
    func feedbackAddress(for control: CompactControl) -> MIDIAddress? {
        guard globalReceiveChannel < 16 else { return nil }
        let type: MIDIAddress.MessageType
        let number: Int
        switch control {
        case let .fader(index):
            guard (1 ... 9).contains(index) else { return nil }
            type = .controlChange; number = index
        case let .encoder(index):
            guard (1 ... 16).contains(index) else { return nil }
            type = .controlChange; number = 25 + index
        case let .button(index):
            guard (1 ... 39).contains(index) else { return nil }
            type = .note; number = index - 1
        case .faderTouch, .encoderPush: return nil
        }
        return MIDIAddress(messageType: type, channel: globalReceiveChannel, number: UInt8(number))
    }

    func encoderRingStyleAddress(encoder: Int) -> MIDIAddress? {
        guard globalReceiveChannel < 16, (1 ... 16).contains(encoder) else { return nil }
        return MIDIAddress(messageType: .controlChange, channel: globalReceiveChannel, number: UInt8(9 + encoder))
    }
}
