import Foundation
import SurfacePluginContracts

public struct ParameterEngine: Sendable {
    public private(set) var configuration: SurfaceConfiguration
    public private(set) var values: [String: Double]
    private let actionBindings: [Int: ActionReference]
    init(validatedConfiguration: ValidatedParameterConfiguration, actionBindings: [Int: ActionReference]) throws {
        let configuration = validatedConfiguration.value
        self.actionBindings = actionBindings
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
