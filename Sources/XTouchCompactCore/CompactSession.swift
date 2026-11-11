import Foundation

/// Two independent application banks. The two physical layers select which bank is exposed;
/// motor travel on bank switch is intentionally opt-in, not a side effect of changing layer.
public struct CompactParameterBank: Equatable, Sendable {
    public var faders: [UInt8] = Array(repeating: 0, count: 9)
    public var encoders: [UInt8] = Array(repeating: 0, count: 16)
    public var buttons: [Bool] = Array(repeating: false, count: 39)

    public init() {}
}

public struct CompactSessionUpdate: Equatable, Sendable {
    public var inputs: [CompactInput]
    public var feedback: [MIDIMessage]

    public init(inputs: [CompactInput] = [], feedback: [MIDIMessage] = []) {
        self.inputs = inputs
        self.feedback = feedback
    }
}

/// Pure/testable orchestration boundary. CoreMIDI and SwiftUI live in the host target.
/// All incoming control events and programmatic writes traverse the same state model.
public struct CompactSession: Sendable {
    public private(set) var state: CompactState
    private var banks: [CompactLayer: CompactParameterBank] = [.a: .init(), .b: .init()]

    public init(map: FactoryStandardMap, lightProtocol: ButtonLightProtocol) {
        state = CompactState(map: map, lightProtocol: lightProtocol)
    }

    public func bank(_ layer: CompactLayer) -> CompactParameterBank { banks[layer] ?? .init() }

    /// Layer assertion is always sent. LED/rings restored from last host state; faders aren't.
    public mutating func connect() throws -> [MIDIMessage] {
        var messages = try state.connect()
        messages += try syncVisibleNonMotorFeedback()
        return messages
    }

    public mutating func selectLayer(_ layer: CompactLayer) throws -> [MIDIMessage] {
        let command = state.selectLayer(layer)
        state.invalidateNonMotorFeedback()
        return [command] + (try syncVisibleNonMotorFeedback())
    }

    /// Explicitly opt in to motor recall after connection or a layer change.
    /// The state model still prevents commands while a fader is touched.
    public mutating func recallFaders() throws -> [MIDIMessage] {
        let values = bank(state.layer).faders
        return try (1...9).flatMap { try state.setFader($0, value: values[$0 - 1]) }
    }

    public mutating func setFader(_ index: Int, value: UInt8, layer: CompactLayer? = nil) throws -> [MIDIMessage] {
        guard (1...9).contains(index) else { throw CompactError.invalidIndex("fader", index) }
        let target = layer ?? state.layer
        banks[target, default: .init()].faders[index - 1] = value
        return target == state.layer ? try state.setFader(index, value: value) : []
    }

    public mutating func setEncoder(_ index: Int, value: UInt8, layer: CompactLayer? = nil) throws -> [MIDIMessage] {
        guard (1...16).contains(index) else { throw CompactError.invalidIndex("encoder", index) }
        let target = layer ?? state.layer
        banks[target, default: .init()].encoders[index - 1] = value
        guard target == state.layer else { return [] }
        return try state.setRing(index, display: .position(Self.ringSegment(for: value)))
    }

    public mutating func toggleButton(_ index: Int, layer: CompactLayer? = nil) throws -> [MIDIMessage] {
        guard (1...39).contains(index) else { throw CompactError.invalidIndex("button", index) }
        let target = layer ?? state.layer
        banks[target, default: .init()].buttons[index - 1].toggle()
        guard target == state.layer else { return [] }
        return try state.setButton(index, light: bank(target).buttons[index - 1] ? .on : .off)
    }

    /// A MIDI callback may contain many events. Apply all of them before publishing UI state.
    /// 'touch released' can yield a motor command only if host desire differs from the last observed position.
    public mutating func receive(_ messages: [MIDIMessage]) throws -> CompactSessionUpdate {
        var result = CompactSessionUpdate()
        for message in messages {
            guard let event = state.receive(message) else { continue }
            result.inputs.append(event)
            switch event.control {
            case let .fader(index):
                result.feedback += try setFader(index, value: event.value, layer: event.layer)
            case let .faderTouch(index):
                if event.isPressed == false { result.feedback += try state.reconcileReleasedFader(index) }
            case let .encoder(index):
                result.feedback += try setEncoder(index, value: event.value, layer: event.layer)
            case let .button(index):
                if event.isPressed == true {
                    result.feedback += try toggleButton(index, layer: event.layer)
                }
                // Local release/transport presses can overwrite feedback without a message
                // describing which other LEDs were redrawn. Reassert invalidated desired state.
                result.feedback += try state.restoreNonMotorFeedback()
            case .encoderPush: break
            }
        }
        return result
    }

    /// On any transport send failure, forget last-sent UI and motor command history. The
    /// caller should re-connect; motor recall remains explicitly user initiated.
    public mutating func invalidateTransportFeedback() {
        state.invalidateNonMotorFeedback()
        state.invalidateMotorCommandHistory()
    }

    private mutating func syncVisibleNonMotorFeedback() throws -> [MIDIMessage] {
        let values = bank(state.layer)
        var result: [MIDIMessage] = []
        for i in 1...16 {
            result += try state.setRing(i, display: .position(Self.ringSegment(for: values.encoders[i - 1])))
        }
        for i in 1...39 {
            result += try state.setButton(i, light: values.buttons[i - 1] ? .on : .off)
        }
        return result
    }

    public static func ringSegment(for value: UInt8) -> Int {
        // The physical ring has 13 steps, not 128. Always show one active LED.
        1 + (Int(value) * 12 + 63) / 127
    }
}
