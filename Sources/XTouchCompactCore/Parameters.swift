import Foundation

public struct ParameterDefinition: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var group: String
    public var unit: String
    public var minimum: Double
    public var maximum: Double
    public var defaultValue: Double
    public var step: Double
    public var isSwitch: Bool
    public var agentWritable: Bool

    public init(id: String, name: String, group: String = "General", unit: String = "", minimum: Double = 0,
                maximum: Double = 127, defaultValue: Double = 0, step: Double = 1,
                isSwitch: Bool = false, agentWritable: Bool = true)
    {
        self.id = id; self.name = name; self.group = group; self.unit = unit
        self.minimum = minimum; self.maximum = maximum; self.defaultValue = defaultValue
        self.step = step; self.isSwitch = isSwitch; self.agentWritable = agentWritable
    }

    public func normalized(_ raw: Double) throws -> Double {
        guard raw.isFinite, minimum.isFinite, maximum.isFinite, minimum < maximum,
              step.isFinite, step >= 0, (maximum - minimum).isFinite else { throw ParameterError.invalidDefinition(id) }
        let value = min(max(raw, minimum), maximum)
        if isSwitch {
            return value >= (minimum + maximum) / 2 ? maximum : minimum
        }
        return step > 0 ? min(max(minimum + ((value - minimum) / step).rounded() * step, minimum), maximum) : value
    }

    public func midiValue(_ value: Double) throws -> UInt8 {
        let value = try normalized(value)
        return UInt8(min(max(((value - minimum) / (maximum - minimum) * 127).rounded(), 0), 127))
    }
}

public enum ParameterAction: Codable, Equatable, Sendable {
    case parameter(String), agent(Int), resetGroup(String), step(String, Double), set(String, Double), cycle(String, [Double])
}

public struct ControlAssignment: Codable, Equatable, Sendable {
    public var control: CompactControl
    public var layer: CompactLayer
    public var action: ParameterAction
    public init(control: CompactControl, layer: CompactLayer, action: ParameterAction) {
        self.control = control; self.layer = layer; self.action = action
    }
}

public struct SurfaceConfiguration: Codable, Equatable, Sendable {
    public var version = 1
    public var device = "X-TOUCH COMPACT"
    public var parameters: [ParameterDefinition]
    public var assignments: [ControlAssignment]

    public init(parameters: [ParameterDefinition], assignments: [ControlAssignment]) {
        self.parameters = parameters; self.assignments = assignments
    }

    public func validate() throws {
        guard version == 1, device == "X-TOUCH COMPACT" else { throw ParameterError.wrongDeviceOrVersion }
        guard Set(parameters.map(\.id)).count == parameters.count else { throw ParameterError.duplicateParameter }
        let ids = Set(parameters.map(\.id))
        var keys = Set<String>()
        let map = try FactoryStandardMap()
        for parameter in parameters {
            guard !parameter.id.isEmpty, !parameter.name.isEmpty else { throw ParameterError.invalidDefinition(parameter.id) }
            _ = try parameter.normalized(parameter.defaultValue)
        }
        for assignment in assignments {
            guard map.inputAddress(for: assignment.control, layer: assignment.layer) != nil,
                  keys.insert("\(assignment.layer.rawValue):\(assignment.control)").inserted else { throw ParameterError.invalidAssignment }
            switch assignment.control {
            case .fader, .encoder:
                guard case .parameter = assignment.action else { throw ParameterError.invalidAssignment }
            default: break
            }
            switch assignment.action {
            case let .agent(slot): guard (1 ... 8).contains(slot) else { throw ParameterError.invalidAssignment }
            case .resetGroup: break
            case let .parameter(id): guard ids.contains(id) else { throw ParameterError.unknownParameter(id) }
            case let .step(id, value), let .set(id, value):
                guard ids.contains(id), value.isFinite else { throw ParameterError.invalidAssignment }
            case let .cycle(id, values):
                guard ids.contains(id), !values.isEmpty, values.allSatisfy(\.isFinite) else { throw ParameterError.invalidAssignment }
            }
        }
    }

    public static var neutral: Self {
        var parameters: [ParameterDefinition] = []
        var assignments: [ControlAssignment] = []
        for layer in CompactLayer.allCases {
            for (kind, count) in [("Fader", 9), ("Encoder", 16)] {
                for index in 1 ... count {
                    let id = "\(layer.rawValue).\(kind).\(index)"
                    parameters.append(ParameterDefinition(id: id, name: "\(kind) \(index)", group: "Layer \(layer.rawValue.uppercased())"))
                    assignments.append(ControlAssignment(control: kind == "Fader" ? .fader(index) : .encoder(index), layer: layer, action: .parameter(id)))
                }
            }
            for slot in 1 ... 8 {
                assignments.append(ControlAssignment(control: .button(slot), layer: layer, action: .agent(slot)))
            }
        }
        return Self(parameters: parameters, assignments: assignments)
    }
}

public enum ParameterError: Error, Equatable {
    case wrongDeviceOrVersion, duplicateParameter, invalidDefinition(String), invalidAssignment, unknownParameter(String), agentDenied(String)
}

public struct ParameterEngine: Sendable {
    public private(set) var configuration: SurfaceConfiguration
    public private(set) var values: [String: Double]
    public init(configuration: SurfaceConfiguration = .neutral) throws {
        try configuration.validate()
        self.configuration = configuration
        values = try Dictionary(uniqueKeysWithValues: configuration.parameters.map { try ($0.id, $0.normalized($0.defaultValue)) })
    }

    public func definition(_ id: String) -> ParameterDefinition? {
        configuration.parameters.first { $0.id == id }
    }

    public func assignment(_ control: CompactControl, layer: CompactLayer) -> ParameterAction? {
        configuration.assignments.first { $0.control == control && $0.layer == layer }?.action
    }

    @discardableResult public mutating func set(_ id: String, value: Double, fromAgent: Bool = false) throws -> Double {
        guard let definition = definition(id) else { throw ParameterError.unknownParameter(id) }
        guard !fromAgent || definition.agentWritable else { throw ParameterError.agentDenied(id) }
        let normalized = try definition.normalized(value)
        values[id] = normalized
        return normalized
    }

    /// Returns an optional Agent slot intent; the host owns its lifecycle.
    public mutating func receive(_ event: CompactInput) throws -> Int? {
        guard let action = assignment(event.control, layer: event.layer) else { return nil }
        switch action {
        case let .parameter(id):
            guard let definition = definition(id) else { throw ParameterError.unknownParameter(id) }
            if event.isPressed == false {
                return nil
            }
            let value = event.isPressed == true ? ((values[id] ?? definition.minimum) == definition.minimum ? definition.maximum : definition.minimum)
                : definition.minimum + Double(event.value) / 127 * (definition.maximum - definition.minimum)
            try set(id, value: value)
        case let .agent(slot): return event.isPressed == true ? slot : nil
        case let .resetGroup(group):
            guard event.isPressed == true else { return nil }
            for p in configuration.parameters where p.group == group {
                try set(p.id, value: p.defaultValue)
            }
        case let .step(id, step):
            if event.isPressed == true {
                try set(id, value: (values[id] ?? 0) + step)
            }
        case let .set(id, value):
            if event.isPressed == true {
                try set(id, value: value)
            }
        case let .cycle(id, choices):
            if event.isPressed == true {
                let next = choices.firstIndex(of: values[id] ?? .nan).map { ($0 + 1) % choices.count } ?? 0
                try set(id, value: choices[next])
            }
        }
        return nil
    }
}

public extension SurfaceConfiguration {
    /// An explicitly loaded example; never selected automatically for connected hardware.
    static var audioExample: Self {
        var configuration = neutral
        for index in configuration.parameters.indices {
            configuration.parameters[index].group = "Audio"
            configuration.parameters[index].unit = "dB"
            configuration.parameters[index].minimum = -60
            configuration.parameters[index].maximum = 6
            configuration.parameters[index].defaultValue = -60
            configuration.parameters[index].step = 0.5
        }
        return configuration
    }
}

extension ParameterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .wrongDeviceOrVersion: "This configuration is not an X-TOUCH COMPACT version 1 configuration."
        case .duplicateParameter: "Parameter IDs must be unique."
        case let .invalidDefinition(id): "Invalid parameter definition: \(id). Check its range and step."
        case .invalidAssignment: "Invalid or duplicate control assignment. Check control range and Agent slot."
        case let .unknownParameter(id): "Unknown parameter: \(id)."
        case let .agentDenied(id): "Agent writes are disabled for parameter: \(id)."
        }
    }
}
