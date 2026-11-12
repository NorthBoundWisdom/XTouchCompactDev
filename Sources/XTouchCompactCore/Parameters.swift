import Foundation
import SurfacePluginContracts

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
    /// Optional for version-1 file compatibility; absent means unprotected.
    public var externallyProtected: Bool?
    /// Optional panel color tag; absent in older files means no tag.
    public var color: ParameterColor?

    public init(id: String, name: String, group: String = "General", unit: String = "", minimum: Double = 0,
                maximum: Double = 127, defaultValue: Double = 0, step: Double = 1,
                isSwitch: Bool = false, agentWritable: Bool = true, externallyProtected: Bool? = nil,
                color: ParameterColor? = nil)
    {
        self.color = color
        self.id = id; self.name = name; self.group = group; self.unit = unit
        self.minimum = minimum; self.maximum = maximum; self.defaultValue = defaultValue
        self.step = step; self.isSwitch = isSwitch; self.agentWritable = agentWritable; self.externallyProtected = externallyProtected
    }

    public func normalized(_ raw: Double) throws -> Double {
        do { return try sharedDefinition.clamp(raw) }
        catch { throw ParameterError.invalidDefinition(id) }
    }

    /// The saved version-1 shape stays host-owned: numeric step 0 means continuous,
    /// and isSwitch is translated only at this configuration boundary.
    public var sharedDefinition: SurfacePluginContracts.ParameterDefinition {
        get throws {
            guard step.isFinite, step >= 0 else { throw ParameterError.invalidDefinition(id) }
            return try .init(id: .init(rawValue: id), nameKey: name, group: group, unit: unit,
                             minimum: minimum, maximum: maximum, defaultValue: defaultValue,
                             kind: isSwitch ? .toggle : .continuous, agentWritable: agentWritable, externallyProtected: externallyProtected ?? false,
                             step: step == 0 ? nil : step)
        }
    }

    public func midiValue(_ value: Double) throws -> UInt8 {
        let value = try normalized(value)
        return UInt8(min(max(((value - minimum) / (maximum - minimum) * 127).rounded(), 0), 127))
    }
}

/// A fixed palette keeps tags legible on the dark panel and stable across file round trips.
public enum ParameterColor: String, Codable, CaseIterable, Sendable {
    case red, orange, yellow, green, teal, blue, purple, pink
}

/// Linked parameters (VCA style): moving the leader by Δ (normalized 0…1) moves every member
/// by the same Δ, each clamped to its own range. Members never move the leader or each other.
public struct ParameterLink: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var leader: String
    public var members: [String]

    public init(id: String, name: String, leader: String, members: [String]) {
        self.id = id; self.name = name; self.leader = leader; self.members = members
    }
}

/// A named set of parameter values. Recall changes host intent only; motors still require
/// the explicit recall action, and touched faders keep their deferral.
public struct ParameterScene: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var values: [String: Double]

    public init(id: String, name: String, values: [String: Double]) {
        self.id = id; self.name = name; self.values = values
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
    /// Optional for older files; nil and empty are equivalent.
    public var links: [ParameterLink]?
    public var scenes: [ParameterScene]?

    public init(parameters: [ParameterDefinition], assignments: [ControlAssignment], version: Int = 1,
                links: [ParameterLink]? = nil, scenes: [ParameterScene]? = nil)
    {
        self.version = version
        self.parameters = parameters; self.assignments = assignments
        self.links = links; self.scenes = scenes
    }

    public func validate() throws {
        guard version == 1 || version == 2, device == "X-TOUCH COMPACT",
              version != 1 || parameters.allSatisfy({ $0.externallyProtected == nil }) else { throw ParameterError.wrongDeviceOrVersion }
        guard Set(parameters.map(\.id)).count == parameters.count else { throw ParameterError.duplicateParameter }
        let ids = Set(parameters.map(\.id))
        try validateLinksAndScenes(ids: ids)
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
            case .fader, .encoder, .expression:
                guard case .parameter = assignment.action else { throw ParameterError.invalidAssignment }
            default: break
            }
            switch assignment.action {
            case let .agent(slot): guard (1 ... 8).contains(slot) else { throw ParameterError.invalidAssignment }
            case let .resetGroup(group):
                guard parameters.contains(where: { $0.group == group }) else { throw ParameterError.invalidAssignment }
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
    case invalidLink(String), invalidScene(String)
}

extension SurfaceConfiguration {
    func validateLinksAndScenes(ids: Set<String>) throws {
        var linkIDs = Set<String>()
        var followers = Set<String>()
        for link in links ?? [] {
            guard !link.id.isEmpty, linkIDs.insert(link.id).inserted,
                  !link.name.trimmingCharacters(in: .whitespaces).isEmpty,
                  ids.contains(link.leader), !link.members.isEmpty,
                  Set(link.members).count == link.members.count,
                  link.members.allSatisfy({ ids.contains($0) && $0 != link.leader })
            else { throw ParameterError.invalidLink(link.id) }
            // One leader per follower and no follower leads: links never chain or loop.
            for member in link.members {
                guard followers.insert(member).inserted else { throw ParameterError.invalidLink(link.id) }
            }
        }
        let leaders = Set((links ?? []).map(\.leader))
        guard leaders.isDisjoint(with: followers) else { throw ParameterError.invalidLink("chain") }
        var sceneIDs = Set<String>()
        for scene in scenes ?? [] {
            guard !scene.id.isEmpty, sceneIDs.insert(scene.id).inserted,
                  !scene.name.trimmingCharacters(in: .whitespaces).isEmpty,
                  scene.values.allSatisfy({ ids.contains($0.key) && $0.value.isFinite })
            else { throw ParameterError.invalidScene(scene.id) }
        }
    }
}

public struct ParameterEngine: Sendable {
    public private(set) var configuration: SurfaceConfiguration
    public private(set) var values: [String: Double]
    private let actionBindings: [Int: ActionReference]
    public init(configuration: SurfaceConfiguration = .neutral, actionBindings: [Int: ActionReference] = PluginConfigurationAdapter.agentActions) throws {
        self.actionBindings = actionBindings
        try configuration.validate()
        self.configuration = configuration
        values = try Dictionary(uniqueKeysWithValues: configuration.parameters.map { try ($0.id, $0.normalized($0.defaultValue)) })
    }

    public func definition(_ id: String) -> ParameterDefinition? {
        configuration.parameters.first { $0.id == id }
    }

    /// Value as a 0…1 fraction of the definition's range (0 for a degenerate range).
    public func normalizedPosition(_ id: String) -> Double? {
        guard let definition = definition(id), let value = values[id] else { return nil }
        let span = definition.maximum - definition.minimum
        return span > 0 ? (value - definition.minimum) / span : 0
    }

    /// Apply a leader's normalized change to its link members. Returns the member IDs whose
    /// value changed. Members are clamped and snapped by their own definitions; Agent writes
    /// that the member forbids are skipped rather than failing the leader's write.
    mutating func propagateLink(from leader: String, delta: Double, fromAgent: Bool) -> Set<String> {
        guard delta != 0, delta.isFinite else { return [] }
        var changed = Set<String>()
        for link in configuration.links ?? [] where link.leader == leader {
            for member in link.members {
                guard let definition = definition(member), let position = normalizedPosition(member) else { continue }
                if fromAgent, !definition.agentWritable || definition.externallyProtected == true {
                    continue
                }
                let target = definition.minimum + min(max(position + delta, 0), 1) * (definition.maximum - definition.minimum)
                let before = values[member]
                if (try? set(member, value: target)) != nil, values[member] != before {
                    changed.insert(member)
                }
            }
        }
        return changed
    }

    public func assignment(_ control: CompactControl, layer: CompactLayer) -> ParameterAction? {
        configuration.assignments.first { $0.control == control && $0.layer == layer }?.action
    }

    @discardableResult public mutating func set(_ id: String, value: Double, fromAgent: Bool = false) throws -> Double {
        guard let definition = definition(id) else { throw ParameterError.unknownParameter(id) }
        guard !fromAgent || (definition.agentWritable && definition.externallyProtected != true) else { throw ParameterError.agentDenied(id) }
        let normalized = try definition.normalized(value)
        values[id] = normalized
        return normalized
    }

    /// Returns a neutral action intent; the host owns plugin lifecycle.
    public mutating func receive(_ event: CompactInput) throws -> ActionReference? {
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
        case let .agent(slot):
            guard event.isPressed == true else { return nil }
            guard let ref = actionBindings[slot] else { throw ParameterError.invalidAssignment }
            return ref
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
                guard let definition = definition(id) else { throw ParameterError.unknownParameter(id) }
                let normalized = try choices.map { try definition.normalized($0) }
                let next = normalized.firstIndex(of: values[id] ?? .nan).map { ($0 + 1) % normalized.count } ?? 0
                try set(id, value: normalized[next])
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
        case .wrongDeviceOrVersion: "This configuration is not a supported X-TOUCH COMPACT version 1 or 2 configuration."
        case .duplicateParameter: "Parameter IDs must be unique."
        case let .invalidDefinition(id): "Invalid parameter definition: \(id). Check its range and step."
        case .invalidAssignment: "Invalid or duplicate control assignment. Check control range and Agent slot."
        case let .unknownParameter(id): "Unknown parameter: \(id)."
        case let .agentDenied(id): "Agent writes are disabled for parameter: \(id)."
        case let .invalidLink(id): "Invalid parameter link: \(id). Leader and members must exist, differ, and not chain."
        case let .invalidScene(id): "Invalid scene: \(id). Scenes need a name and finite values for existing parameters."
        }
    }
}
