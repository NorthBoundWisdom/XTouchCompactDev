import Foundation

/// MIDI 1.0 channel-voice messages as Universal MIDI Packets (message type 0x2).
/// Based on the value-oriented CoreMIDI codec approach in BCR2000Dev, extended here
/// with Program Change and Pitch Bend for the Compact. System messages are ignored.
public enum MIDI1UMPCodec {
    public static func decode(_ word: UInt32) -> MIDIMessage? {
        guard (word >> 28) & 0xF == 0x2 else { return nil }
        let status = UInt8((word >> 20) & 0xF)
        let channel = UInt8((word >> 16) & 0xF)
        let data1 = UInt8((word >> 8) & 0x7F)
        let data2 = UInt8(word & 0x7F)
        switch status {
        case 0x8: return .noteOff(channel: channel, number: data1, velocity: data2)
        case 0x9:
            return data2 == 0 ? .noteOff(channel: channel, number: data1, velocity: 0)
                : .noteOn(channel: channel, number: data1, velocity: data2)
        case 0xB: return .controlChange(channel: channel, number: data1, value: data2)
        case 0xC: return .programChange(channel: channel, number: data1)
        case 0xE: return .pitchBend(channel: channel, value: UInt16(data1) | (UInt16(data2) << 7))
        default: return nil
        }
    }

    public static func encode(_ message: MIDIMessage, group: UInt8 = 0) -> UInt32 {
        precondition(group < 16, "MIDI group out of range")
        let status: UInt8
        let channel: UInt8
        let data1: UInt8
        let data2: UInt8
        switch message {
        case let .noteOff(c, n, v): (status, channel, data1, data2) = (0x8, c, n, v)
        case let .noteOn(c, n, v): (status, channel, data1, data2) = (0x9, c, n, v)
        case let .controlChange(c, n, v): (status, channel, data1, data2) = (0xB, c, n, v)
        case let .programChange(c, n): (status, channel, data1, data2) = (0xC, c, n, 0)
        case let .pitchBend(c, v):
            (status, channel, data1, data2) = (0xE, c, UInt8(v & 0x7F), UInt8((v >> 7) & 0x7F))
        }
        return (0x2 << 28) | (UInt32(group) << 24) | (UInt32(status) << 20)
            | (UInt32(channel) << 16) | (UInt32(data1) << 8) | UInt32(data2)
    }
}
