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
    public private(set) var reviews: [CompactLayer: [CompactControl: ControlInputReview]] = [:]
    public private(set) var crossLayerReleases: [CrossLayerRelease: Int] = [:]
    private var heldOrigins: [CompactControl: CompactLayer] = [:]
    private var heldOtherLayers: [CompactControl: CompactLayer] = [:]

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
        recordReview(input, message: message, at: time)
        switch input.control {
        case let .fader(i): faderPositions[i] = input.value
        case let .faderTouch(i): faderTouches[i] = input.isPressed
        case let .encoder(i): encoderValues[input.layer, default: [:]][i] = input.value
        case let .encoderPush(i): encoderPushes[i] = input.isPressed
        case let .button(i): buttonPresses[i] = input.isPressed
        }
    }

    private mutating func recordReview(_ input: CompactInput, message: MIDIMessage, at time: Date) {
        // Preserve positive layer evidence while a control is held. A release may
        // use the original layer's address even after another-layer rotation report.
        for (control, origin) in heldOrigins where origin != input.layer {
            if control != input.control || input.isPressed != false {
                heldOtherLayers[control] = input.layer
            }
        }
        let address: MIDIAddress
        switch message {
        case let .controlChange(channel, number, _): address = MIDIAddress(messageType: .controlChange, channel: channel, number: number)
        case let .noteOn(channel, number, _), let .noteOff(channel, number, _): address = MIDIAddress(messageType: .note, channel: channel, number: number)
        default: return
        }
        var review = reviews[input.layer]?[input.control] ?? .init()
        review.record(input, address: address, at: time)
        if let pressed = input.isPressed {
            if pressed {
                if heldOrigins[input.control] != nil {
                    review.recordDuplicatePress()
                } else {
                    heldOrigins[input.control] = input.layer
                }
            } else if let origin = heldOrigins.removeValue(forKey: input.control) {
                let interveningLayer = heldOtherLayers.removeValue(forKey: input.control)
                if origin == input.layer {
                    review.recordPair()
                } else {
                    var originReview = reviews[origin]?[input.control] ?? .init()
                    originReview.recordPair()
                    reviews[origin, default: [:]][input.control] = originReview
                }
                if origin != input.layer || interveningLayer != nil {
                    crossLayerReleases[CrossLayerRelease(control: input.control, pressedLayer: origin, releasedLayer: input.layer, interveningLayer: interveningLayer), default: 0] += 1
                }
            } else {
                review.recordUnmatchedRelease()
            }
        }
        reviews[input.layer, default: [:]][input.control] = review
    }
}
