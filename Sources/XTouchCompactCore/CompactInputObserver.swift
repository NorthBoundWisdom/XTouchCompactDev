import Foundation

/// An actual input message and its interpretation under the applied factory map.
/// Channels remain zero-based here, like every other protocol/core channel.
public struct CompactInputObservation: Equatable, Identifiable, Sendable {
    public let id: Int
    public let timestamp: Date
    public let message: MIDIMessage
    public let input: CompactInput?
    public let channel: UInt8
    public let matchesConfiguredChannel: Bool
}

/// Passive input accumulation, independent of transports, parameters and presentation.
/// Missing values mean unobserved. A bounded history never truncates control coverage
/// or the last reported physical state. No command can update these observations.
public struct CompactInputObserver: Equatable, Sendable {
    public private(set) var messageCount = 0
    public private(set) var recent: [CompactInputObservation] = []
    public private(set) var faderPositions: [Int: UInt8] = [:]
    public private(set) var faderTouches: [Int: Bool] = [:]
    public private(set) var encoderValues: [CompactLayer: [Int: UInt8]] = [:]
    public private(set) var encoderPushes: [Int: Bool] = [:]
    public private(set) var buttonPresses: [Int: Bool] = [:]
    public private(set) var seenControls: Set<CompactControl> = []
    public private(set) var inputLayer: CompactLayer?

    public init() {}

    public mutating func receive(_ message: MIDIMessage, map: FactoryStandardMap, at time: Date) {
        let channel: UInt8 = switch message {
        case let .controlChange(c, _, _), let .noteOn(c, _, _), let .noteOff(c, _, _),
             let .programChange(c, _), let .pitchBend(c, _): c
        }
        let input = map.decode(message)
        messageCount += 1
        recent.insert(CompactInputObservation(
            id: messageCount, timestamp: time, message: message, input: input,
            channel: channel, matchesConfiguredChannel: channel == map.transmitChannel
        ), at: 0)
        if recent.count > 12 {
            recent.removeLast()
        }
        guard let input else { return }
        inputLayer = input.layer
        seenControls.insert(input.control)
        switch input.control {
        case let .fader(i): faderPositions[i] = input.value
        case let .faderTouch(i): faderTouches[i] = input.isPressed
        case let .encoder(i): encoderValues[input.layer, default: [:]][i] = input.value
        case let .encoderPush(i): encoderPushes[i] = input.isPressed
        case let .button(i): buttonPresses[i] = input.isPressed
        }
    }
}
