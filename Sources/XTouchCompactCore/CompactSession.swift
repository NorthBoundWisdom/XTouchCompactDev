import Foundation
import SurfacePluginContracts

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
    public var actionIntents: [ActionReference] = []

    public init(inputs: [CompactInput] = [], feedback: [MIDIMessage] = []) {
        self.inputs = inputs
        self.feedback = feedback
    }
}

/// Pure/testable orchestration boundary. CoreMIDI and SwiftUI live in the host target.
/// All incoming control events and programmatic writes traverse the same state model.
public struct CompactSession: Sendable {
    public private(set) var state: CompactState
    public private(set) var parameters = try! ParameterEngine()
    private var indicators: [IndicatorID: IndicatorState] = [:]
    private let indicatorBindings: [Int: IndicatorID]
    private var banks: [CompactLayer: CompactParameterBank] = [.a: .init(), .b: .init()]

    public init(map: FactoryStandardMap, lightProtocol: ButtonLightProtocol, indicatorBindings: [Int: IndicatorID] = PluginConfigurationAdapter.agentIndicators) {
        self.indicatorBindings = indicatorBindings
        state = CompactState(map: map, lightProtocol: lightProtocol)
        // Establish software-owned display intent even while disconnected. These fixed
        // indices and ring positions are valid by construction; no transport is involved.
        _ = try! syncVisibleNonMotorFeedback()
        state.invalidateNonMotorFeedback()
    }

    public mutating func reconfigure(map: FactoryStandardMap, lightProtocol: ButtonLightProtocol) throws -> [MIDIMessage] {
        state = state.reconfigured(map: map, lightProtocol: lightProtocol)
        return try [map.selectLayer(state.layer)] + syncVisibleNonMotorFeedback()
    }

    public func bank(_ layer: CompactLayer) -> CompactParameterBank {
        banks[layer] ?? .init()
    }

    /// Layer assertion is always sent. LED/rings restored from last host state; faders aren't.
    public mutating func connect() throws -> [MIDIMessage] {
        var messages = try state.connect()
        messages += try syncVisibleNonMotorFeedback()
        return messages
    }

    public mutating func selectLayer(_ layer: CompactLayer) throws -> [MIDIMessage] {
        let command = state.selectLayer(layer)
        state.invalidateNonMotorFeedback()
        return try [command] + syncVisibleNonMotorFeedback()
    }

    /// Explicitly opt in to motor recall after connection or a layer change.
    /// The state model still prevents commands while a fader is touched.
    public mutating func recallFaders() throws -> [MIDIMessage] {
        let values = bank(state.layer).faders
        return try (1 ... 9).flatMap { try state.setFader($0, value: values[$0 - 1]) }
    }

    public mutating func setSafetyTouch(_ index: Int, touched: Bool) {
        state.setSafetyTouch(index, touched: touched)
    }

    public mutating func prepareTransportSwitch(inputTouches: Set<Int>) {
        state.cancelMotorIntents(); state.setInputTouches(inputTouches)
    }

    public mutating func discardPendingMotorWrites() {
        state.discardPendingMotorWrites()
    }

    public mutating func setInputTouches(_ touches: Set<Int>) {
        state.setInputTouches(touches)
    }

    /// Passive diagnostics track physical state and layer safety without executing any
    /// assignment, changing parameter values or producing feedback/Agent actions.
    public mutating func observeInputs(_ messages: [MIDIMessage]) {
        for message in messages {
            _ = state.receive(message)
        }
    }

    public mutating func updateIndicators(_ states: [IndicatorID: IndicatorState]) throws -> [MIDIMessage] {
        indicators = states
        return try syncVisibleNonMotorFeedback()
    }

    public mutating func setParameter(_ id: String, value: Double, fromAgent: Bool = false) throws -> [MIDIMessage] {
        try parameters.set(id, value: value, fromAgent: fromAgent)
        return try synchronizeParameters(ids: [id])
    }

    public var hasNonDefaultValues: Bool {
        for definition in parameters.configuration.parameters {
            if let value = parameters.values[definition.id], value != (try? definition.normalized(definition.defaultValue)) {
                return true
            }
        }
        for layer in CompactLayer.allCases {
            for index in 1 ... 9 where parameters.assignment(.fader(index), layer: layer) == nil {
                if bank(layer).faders[index - 1] != 0 {
                    return true
                }
            }
            for index in 1 ... 16 where parameters.assignment(.encoder(index), layer: layer) == nil {
                if bank(layer).encoders[index - 1] != 0 {
                    return true
                }
            }
        }
        return false
    }

    public mutating func loadConfiguration(_ configuration: SurfaceConfiguration, resetValues: Bool = false) throws -> [MIDIMessage] {
        var next = try ParameterEngine(configuration: configuration)
        if !resetValues {
            for (id, value) in parameters.values where next.definition(id) != nil {
                try next.set(id, value: value)
            }
        }
        parameters = next
        if resetValues {
            banks = [.a: .init(), .b: .init()]
        }
        // Loading a preset is not permission to move motors.
        state = state.reconfigured(map: state.map, lightProtocol: state.lightProtocol)
        return try synchronizeParameters(includeMotors: false) + syncVisibleNonMotorFeedback()
    }

    private mutating func synchronizeParameters(includeMotors: Bool = true, ids: Set<String>? = nil, excludingFader: Int? = nil) throws -> [MIDIMessage] {
        var messages: [MIDIMessage] = []
        for assignment in parameters.configuration.assignments {
            guard case let .parameter(id) = assignment.action, ids == nil || ids!.contains(id),
                  let definition = parameters.definition(id), let value = parameters.values[id] else { continue }
            let raw = try definition.midiValue(value)
            switch assignment.control {
            case let .fader(index):
                banks[assignment.layer, default: .init()].faders[index - 1] = raw
                if includeMotors, assignment.layer == state.layer, index != excludingFader {
                    messages += try state.setFader(index, value: raw)
                }
            case let .encoder(index):
                banks[assignment.layer, default: .init()].encoders[index - 1] = raw
                if assignment.layer == state.layer {
                    messages += try state.setRing(index, display: .position(Self.ringSegment(for: raw)))
                }
            case let .button(index):
                banks[assignment.layer, default: .init()].buttons[index - 1] = raw > 0
                if assignment.layer == state.layer {
                    messages += try state.setButton(index, light: raw > 0 ? .on : .off)
                }
            default: break
            }
        }
        return messages
    }

    public mutating func setFader(_ index: Int, value: UInt8, layer: CompactLayer? = nil) throws -> [MIDIMessage] {
        guard (1 ... 9).contains(index) else { throw CompactError.invalidIndex("fader", index) }
        let target = layer ?? state.layer
        if case let .parameter(id) = parameters.assignment(.fader(index), layer: target),
           let definition = parameters.definition(id)
        {
            return try setParameter(id, value: definition.minimum + Double(value) / 127 * (definition.maximum - definition.minimum))
        }
        banks[target, default: .init()].faders[index - 1] = value
        return target == state.layer ? try state.setFader(index, value: value) : []
    }

    public mutating func setEncoder(_ index: Int, value: UInt8, layer: CompactLayer? = nil) throws -> [MIDIMessage] {
        guard (1 ... 16).contains(index) else { throw CompactError.invalidIndex("encoder", index) }
        let target = layer ?? state.layer
        if case let .parameter(id) = parameters.assignment(.encoder(index), layer: target),
           let definition = parameters.definition(id)
        {
            return try setParameter(id, value: definition.minimum + Double(value) / 127 * (definition.maximum - definition.minimum))
        }
        banks[target, default: .init()].encoders[index - 1] = value
        guard target == state.layer else { return [] }
        return try state.setRing(index, display: .position(Self.ringSegment(for: value)))
    }

    public mutating func activateButton(_ index: Int) throws -> CompactSessionUpdate {
        guard (1 ... 39).contains(index) else { throw CompactError.invalidIndex("button", index) }
        let before = parameters.values
        let slot = try parameters.receive(CompactInput(control: .button(index), layer: state.layer, value: 127, isPressed: true))
        var update = try CompactSessionUpdate(feedback: synchronizeParameters(ids: Set(parameters.values.keys.filter { before[$0] != parameters.values[$0] })))
        if let slot {
            update.actionIntents = [slot]
        }
        return update
    }

    /// A MIDI callback may contain many events. Apply all of them before publishing UI state.
    /// 'touch released' can yield a motor command only if host desire differs from the last observed position.
    public mutating func receive(_ messages: [MIDIMessage]) throws -> CompactSessionUpdate {
        var result = CompactSessionUpdate()
        for message in messages {
            guard let event = state.receive(message) else { continue }
            result.inputs.append(event)
            if event.layer != state.layer {
                // Other-layer messages are physical safety evidence, never an active-bank edit.
                continue
            }
            switch event.control {
            case let .fader(index):
                state.acceptPhysicalFader(index)
                if case let .parameter(id) = parameters.assignment(.fader(index), layer: event.layer),
                   let definition = parameters.definition(id)
                {
                    try parameters.set(id, value: definition.minimum + Double(event.value) / 127 * (definition.maximum - definition.minimum))
                    // Without touch evidence this may be motor-progress feedback. Never let it
                    // drive another motor and bounce back through a shared binding.
                    result.feedback += try synchronizeParameters(includeMotors: state.isTouched(index), ids: [id], excludingFader: index)
                } else {
                    banks[event.layer, default: .init()].faders[index - 1] = event.value
                }
            case let .faderTouch(index):
                let previous = parameters.values
                if let slot = try parameters.receive(event) {
                    result.actionIntents.append(slot)
                }
                result.feedback += try synchronizeParameters(ids: Set(parameters.values.keys.filter { previous[$0] != parameters.values[$0] }))
                if event.isPressed == false {
                    result.feedback += try state.reconcileReleasedFader(index)
                }
            case let .encoder(index):
                result.feedback += try setEncoder(index, value: event.value, layer: event.layer)
            case .button:
                let previous = parameters.values
                if let slot = try parameters.receive(event) {
                    result.actionIntents.append(slot)
                }
                let changed = Set(parameters.values.keys.filter { previous[$0] != parameters.values[$0] })
                result.feedback += try synchronizeParameters(ids: changed)
                // Local release/transport presses can overwrite feedback without a message
                // describing which other LEDs were redrawn. Reassert invalidated desired state.
                result.feedback += try state.restoreNonMotorFeedback()
            case .encoderPush:
                let previous = parameters.values
                if let slot = try parameters.receive(event) {
                    result.actionIntents.append(slot)
                }
                result.feedback += try synchronizeParameters(ids: Set(parameters.values.keys.filter { previous[$0] != parameters.values[$0] }))
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

    /// Explicit diagnostic LED/ring writes can replace cached feedback without
    /// changing parameter authority or asserting a physical motor observation.
    public mutating func invalidateNonMotorFeedback() {
        state.invalidateNonMotorFeedback()
    }

    private mutating func syncVisibleNonMotorFeedback() throws -> [MIDIMessage] {
        let values = bank(state.layer)
        var result: [MIDIMessage] = []
        for i in 1 ... 16 {
            result += try state.setRing(i, display: .position(Self.ringSegment(for: values.encoders[i - 1])))
        }
        for i in 1 ... 39 {
            let light: ButtonLight = switch parameters.assignment(.button(i), layer: state.layer) {
            case let .agent(slot): indicatorBindings[slot].flatMap { indicators[$0] }.map(IndicatorPresentation.light) ?? .off
            case .parameter: values.buttons[i - 1] ? .on : .off
            default: .off
            }
            result += try state.setButton(i, light: light)
        }
        return result
    }

    public static func ringSegment(for value: UInt8) -> Int {
        // The physical ring has 13 steps, not 128. Always show one active LED.
        1 + (Int(value) * 12 + 63) / 127
    }
}
