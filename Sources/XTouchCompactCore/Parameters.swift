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
}

public enum ParameterError: Error, Equatable {
    case wrongDeviceOrVersion, duplicateParameter, invalidDefinition(String), invalidAssignment, unknownParameter(String), agentDenied(String)
    case invalidLink(String), invalidScene(String)
}

/// Internal evidence passed from the device-aware construction adapter to the value engine.
struct ValidatedParameterConfiguration: Sendable {
    let value: SurfaceConfiguration
}
