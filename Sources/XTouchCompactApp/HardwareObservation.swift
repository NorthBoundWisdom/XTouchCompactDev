#if os(macOS)
    import Foundation
    import XTouchCompactCore

    /// Facts received from the physical input only. Missing entries are unobserved,
    /// including touch/release state; host commands and mock gestures never populate these.
    struct HardwareObservationPresentation: Equatable, Sendable {
        var messageCount = 0
        var recent: [ObservedHardwareInput] = []
        var faderPositions: [Int: UInt8] = [:]
        var faderTouches: [Int: Bool] = [:]
        var encoderValues: [CompactLayer: [Int: UInt8]] = [:]
        var encoderPushes: [Int: Bool] = [:]
        var buttonPresses: [Int: Bool] = [:]
        var seenControls: Set<CompactControl> = []
        var inputLayer: CompactLayer?
        var isPreview = false

        var latest: ObservedHardwareInput? {
            recent.first
        }
    }

    struct ObservedHardwareInput: Equatable, Identifiable, Sendable {
        let id: Int
        let timestamp: Date
        let message: MIDIMessage
        let input: CompactInput?
        let channel: Int
        let matchesConfiguredChannel: Bool

        var panelControl: CompactControl? {
            switch input?.control {
            case let .faderTouch(index): .fader(index)
            case let .encoderPush(index): .encoder(index)
            default: input?.control
            }
        }
    }

    /// Diagnostic accumulator, independent of parameter assignments and the 120-row monitor.
    struct HardwareInputObserver {
        private(set) var presentation = HardwareObservationPresentation()

        mutating func receive(_ message: MIDIMessage, map: FactoryStandardMap, at time: Date) {
            let channel: UInt8 = switch message {
            case let .controlChange(c, _, _), let .noteOn(c, _, _), let .noteOff(c, _, _),
                 let .programChange(c, _), let .pitchBend(c, _): c
            }
            let input = map.decode(message)
            presentation.messageCount += 1
            presentation.recent.insert(ObservedHardwareInput(
                id: presentation.messageCount, timestamp: time, message: message, input: input,
                channel: Int(channel) + 1, matchesConfiguredChannel: channel == map.transmitChannel
            ), at: 0)
            if presentation.recent.count > 12 {
                presentation.recent.removeLast()
            }
            guard let input else { return }
            presentation.inputLayer = input.layer
            presentation.seenControls.insert(input.control)
            switch input.control {
            case let .fader(i): presentation.faderPositions[i] = input.value
            case let .faderTouch(i): presentation.faderTouches[i] = input.isPressed
            case let .encoder(i): presentation.encoderValues[input.layer, default: [:]][i] = input.value
            case let .encoderPush(i): presentation.encoderPushes[i] = input.isPressed
            case let .button(i): presentation.buttonPresses[i] = input.isPressed
            }
        }
    }
#endif
