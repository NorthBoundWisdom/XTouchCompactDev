import Foundation
import SurfaceControlContracts
import SurfacePluginContracts
import RemoteToolContracts

/// Isolated software surface. This composition has no MIDI transport, user store,
/// system clock or business workflow. The existing session and device model own all
/// interactions; the shared contract owns validation and the public event cursor.
public struct CompactSurfaceSimulator: Sendable {
    public private(set) var session: CompactSession
    public private(set) var mock: MockXTouchCompact
    public private(set) var controls: SurfaceControlSession
    private let configuration: SurfaceConfiguration

    public static let profileID = "xtouch.compact.standard.simulation"
    public static let profileVersion = "1.0"
    public static var demonstrationConfiguration: SurfaceConfiguration {
        let roles = ["arm", "start", "pause", "cancel"]
        var parameters = roles.map { ParameterDefinition(id: "simulation.\($0)", name: $0) }
        parameters += [ParameterDefinition(id: "simulation.state", name: "State", isSwitch: true),
            ParameterDefinition(id: "simulation.progress", name: "Progress"),
            ParameterDefinition(id: "simulation.link", name: "Link", isSwitch: true)]
        var assignments = roles.enumerated().map { ControlAssignment(control: .encoder($0.offset + 1), layer: .a, action: .parameter("simulation.\($0.element)")) }
        assignments += [.init(control: .button(1), layer: .a, action: .parameter("simulation.state")),
            .init(control: .encoder(5), layer: .a, action: .parameter("simulation.progress")),
            .init(control: .button(2), layer: .a, action: .parameter("simulation.link"))]
        return SurfaceConfiguration(parameters: parameters, assignments: assignments)
    }
    public init(instanceID: String, epoch: String, mappingRevision: String = "1", configuration: SurfaceConfiguration = Self.demonstrationConfiguration, eventCapacity: Int = 1024) throws {
        self.configuration = configuration
        let map = try FactoryStandardMap()
        session = CompactSession(map: map, lightProtocol: .manual, indicatorBindings: [:])
        mock = MockXTouchCompact(map: map, lightProtocol: .manual)
        _ = try session.loadConfiguration(configuration, resetValues: true)
        mock.receive(try session.connect())
        controls = try SurfaceControlSession(instanceID: instanceID, epoch: epoch, mappingRevision: mappingRevision,
            profile: Self.profile(configuration: configuration), eventCapacity: eventCapacity)
        try controls.seedInputs(mockInputs(), at: 0)
    }

    public static func profile(configuration: SurfaceConfiguration) -> ControlProfile {
        var descriptors: [ControlDescriptor] = []
        for layer in CompactLayer.allCases {
            for (kind, count) in [("fader", 9), ("touch", 9), ("encoder", 16), ("push", 16), ("button", 39)] {
                for index in 1 ... count {
                    let control = compactControl(kind: kind, index: index)!
                    let absolute = kind == "fader" || kind == "encoder"
                    var mapping: ControlMapping?
                    if case let .parameter(id) = configuration.assignments.first(where: { $0.layer == layer && $0.control == control })?.action {
                        mapping = ControlMapping(kind: .parameter, id: id)
                    }
                    descriptors.append(.init(id: "\(layer.rawValue).\(kind).\(index)", inputKind: absolute ? .absolute : .button,
                        encoding: absolute ? .scalar : .boolean,
                        range: absolute ? .init(minimum: 0, maximum: 127, step: 1) : nil,
                        feedbackKinds: absolute ? [.value] : (kind == "button" ? [.indicator] : []), mapping: mapping))
                }
            }
        }
        return .init(id: profileID, version: profileVersion, controls: descriptors,
            capabilities: ["simulation", "display_feedback", "absolute_input", "button_input", "layered_controls", "touch_protection"])
    }

    @discardableResult public mutating func input(_ input: ControlInput, at time: Double) throws -> ControlEvent {
        _ = try controls.validateInput(input, at: time)
        var next = self
        let (layer, kind, index) = try Self.address(input.control_id)
        var disposition: ControlDisposition = .accepted
        var reason: String?
        var mapped: JSONValue?
        if layer == session.state.layer { try validateExternalWrite(kind: kind, index: index, layer: layer) }
        if layer != session.state.layer {
            disposition = .ignored; reason = "inactive_layer"
        } else if (try controls.snapshot(at: time)).inputs[input.control_id] == input.value {
            disposition = .ignored; reason = "no_change"
        } else {
            let messages: [MIDIMessage]
            switch kind {
            case "fader": messages = try next.mock.moveFader(index, value: UInt8(input.value.finiteNumber!))
            case "encoder": messages = try next.mock.turnEncoder(index, value: UInt8(input.value.finiteNumber!))
            case "touch": messages = try next.mock.touchFader(index, isTouched: input.value == .bool(true))
            case "push": messages = try next.mock.pushEncoder(index, isDown: input.value == .bool(true))
            case "button": messages = try next.mock.pressButton(index, isDown: input.value == .bool(true))
            default: throw ControlContractError("unsupported_control")
            }
            let update = try next.session.receive(messages)
            // Only parameter mappings are exposed by this software composition.
            // New action bindings require an explicit host composition, not a bypass.
            guard update.actionIntents.isEmpty else { throw ControlContractError("unsupported_mapping") }
            next.mock.receive(update.feedback)
            for (id, channels) in (try next.controls.snapshot(at: time)).feedback {
                for (channel, value) in channels {
                    try next.applyDisplay(.init(expected: next.controls.expected, expectedSequence: next.controls.discovery().latest_sequence, controlID: id, kind: channel, value: value))
                }
            }
            if case let .parameter(id) = next.session.parameters.assignment(Self.compactControl(kind: kind, index: index)!, layer: layer),
               let value = next.session.parameters.values[id] { mapped = .double(value) }
        }
        let event = try next.controls.recordInput(input, disposition: disposition, mappedValue: mapped, reason: reason, origin: .remote, at: time)
        self = next
        return event
    }

    private func validateExternalWrite(kind: String, index: Int, layer: CompactLayer) throws {
        guard let action = session.parameters.assignment(Self.compactControl(kind: kind, index: index)!, layer: layer) else { return }
        let ids: [String]
        switch action {
        case let .parameter(id): ids = [id]
        case .step, .set, .cycle, .resetGroup, .agent: throw ControlContractError("unsupported_mapping")
        }
        guard ids.allSatisfy({ id in session.parameters.definition(id).map { $0.agentWritable && $0.externallyProtected != true } ?? false }) else {
            throw ControlContractError("permission_denied")
        }
    }

    @discardableResult public mutating func feedback(_ feedback: ControlFeedback, at time: Double) throws -> ControlEvent {
        _ = try controls.validateFeedback(feedback, at: time)
        var next = self
        let (layer, _, _) = try Self.address(feedback.control_id)
        let active = layer == next.session.state.layer
        if active { try next.applyDisplay(feedback) }
        let event = try next.controls.recordFeedback(feedback, disposition: active ? .accepted : .ignored,
            reason: active ? nil : "inactive_layer", origin: .remote, at: time)
        self = next
        return event
    }

    private mutating func applyDisplay(_ feedback: ControlFeedback) throws {
        let (layer, kind, index) = try Self.address(feedback.control_id)
        guard layer == session.state.layer else { return }
        let messages: [MIDIMessage]
        switch kind {
        case "encoder": messages = try session.setDisplayRing(index, value: UInt8(feedback.value.finiteNumber!))
        case "fader": messages = try session.setDisplayFader(index, value: UInt8(feedback.value.finiteNumber!))
        case "button":
            let light: ButtonLight = feedback.value == .string("on") ? .on : (feedback.value == .string("blink") ? .blink : .off)
            messages = try session.setDisplayButton(index, light: light)
        default: throw ControlContractError("unsupported_feedback")
        }
        mock.receive(messages)
    }

    /// Rotation is a host lifecycle operation. Fresh epochs must come from host
    /// entropy; a remote reset can never choose or reuse a generation.
    public mutating func reset(expected: ControlExpected, expectedSequence: String, epoch: String, at time: Double) throws {
        var nextControls = controls
        try nextControls.reset(expected: expected, expectedSequence: expectedSequence, epoch: epoch, mappingRevision: expected.mapping_revision, at: time)
        var next = try Self(instanceID: expected.instance_id, epoch: epoch, mappingRevision: expected.mapping_revision,
            configuration: configuration, eventCapacity: controls.eventCapacity)
        try nextControls.seedInputs(next.mockInputs(), at: time)
        next.controls = nextControls
        self = next
    }
    public mutating func reset(epoch: String, at time: Double) throws {
        try reset(expected: controls.expected, expectedSequence: controls.discovery().latest_sequence, epoch: epoch, at: time)
    }
    public mutating func selectLayer(_ layer: CompactLayer, epoch: String, at time: Double) throws {
        guard epoch != controls.expected.epoch else { throw ControlContractError("invalid_argument") }
        var next = self
        next.mock.receive(try next.session.selectLayer(layer))
        let expected = controls.discovery().expected
        try next.controls.reset(expected: expected, expectedSequence: controls.discovery().latest_sequence,
            epoch: epoch, mappingRevision: expected.mapping_revision, at: time)
        try next.controls.seedInputs(next.mockInputs(), at: time)
        self = next
    }

    private func mockInputs() -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for layer in CompactLayer.allCases {
            for index in 1 ... 9 {
                values["\(layer.rawValue).fader.\(index)"] = .number(Int(mock.faders[index - 1]))
                values["\(layer.rawValue).touch.\(index)"] = .bool(mock.touchedFaders.contains(index))
            }
            for index in 1 ... 16 {
                values["\(layer.rawValue).encoder.\(index)"] = .number(Int(mock.encoders[index - 1]))
                values["\(layer.rawValue).push.\(index)"] = .bool(mock.pushedEncoders.contains(index))
            }
            for index in 1 ... 39 { values["\(layer.rawValue).button.\(index)"] = .bool(mock.pressedButtons.contains(index)) }
        }
        return values
    }

    private static func compactControl(kind: String, index: Int) -> CompactControl? {
        switch kind { case "fader": .fader(index); case "touch": .faderTouch(index); case "encoder": .encoder(index); case "push": .encoderPush(index); case "button": .button(index); default: nil }
    }
    private static func address(_ id: String) throws -> (CompactLayer, String, Int) {
        let parts = id.split(separator: ".")
        guard parts.count == 3, let layer = CompactLayer(rawValue: String(parts[0])), let index = Int(parts[2]), compactControl(kind: String(parts[1]), index: index) != nil else { throw ControlContractError("unsupported_control") }
        return (layer, String(parts[1]), index)
    }
}
