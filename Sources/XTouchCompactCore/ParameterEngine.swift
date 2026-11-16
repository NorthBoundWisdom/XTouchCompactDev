import Foundation
import SurfaceBindingContext
import SurfacePluginContracts

public struct ParameterEngine: Sendable {
    #if DEBUG
        package var bindingReference: (any CompactBindingReference)?
        package var contextAudit: (any CompactContextAuditReader)? {
            bindingReference?.audit
        }

        func reconfiguredReference(_ configuration: SurfaceConfiguration) -> (any CompactBindingReference)? {
            var copy = bindingReference
            copy?.replace(configuration: configuration)
            return copy
        }
    #endif
    private var bindingContext: BindingContextState
    public private(set) var configuration: SurfaceConfiguration
    public private(set) var values: [String: Double]
    public private(set) var writeAuthorization = ParameterWriteAuthorization()
    private let actionBindings: [Int: ActionReference]
    init(validatedConfiguration: ValidatedParameterConfiguration, actionBindings: [Int: ActionReference]) throws {
        let configuration = validatedConfiguration.value
        self.actionBindings = actionBindings
        self.configuration = configuration
        bindingContext = .init(CompactBindingKey.context(configuration, generation: 0))
        values = try Dictionary(uniqueKeysWithValues: configuration.parameters.map { try ($0.id, $0.normalized($0.defaultValue)) })
    }

    public mutating func configureWriteAuthorization(_ context: ParameterWriteAuthorization) {
        writeAuthorization = context
        let transition = bindingContext.apply(CompactBindingKey.context(configuration, generation: context.bindingGeneration))
        #if DEBUG
            bindingReference?.configure(generation: context.bindingGeneration, changed: transition.contextChanged)
        #endif
    }

    public func validateWrite(_ id: String, writer: ParameterWriter) throws {
        try writeAuthorization.validate(parameterID: id, writer: writer,
                                        routeGeneration: writeAuthorization.routeGeneration, bindingGeneration: writeAuthorization.bindingGeneration)
    }

    /// A trusted authority correction changes the existing owner, never a physical observation.
    mutating func receiveAuthority(_ id: String, accepted _: Bool, actualValue: Double,
                                   routeGeneration: UInt64, bindingGeneration: UInt64) throws
    {
        guard routeGeneration == writeAuthorization.routeGeneration, bindingGeneration == writeAuthorization.bindingGeneration else {
            throw ParameterWriteAuthorizationError.staleContext
        }
        guard actualValue.isFinite else { throw ParameterWriteAuthorizationError.invalidAuthorityValue }
        guard let definition = definition(id) else { throw ParameterError.unknownParameter(id) }
        let corrected = try definition.normalized(actualValue)
        guard corrected == actualValue else { throw ParameterWriteAuthorizationError.invalidAuthorityValue }
        values[id] = corrected
        // Acceptance is interpreted by the trusted host; no second authority or cached veto lives here.
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
    mutating func propagateLink(from leader: String, delta: Double, fromAgent: Bool, writer: ParameterWriter? = nil) -> Set<String> {
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
                if (try? set(member, value: target, fromAgent: fromAgent, writer: writer)) != nil, values[member] != before {
                    changed.insert(member)
                }
            }
        }
        return changed
    }

    public func assignment(_ control: CompactControl, layer: CompactLayer) -> ParameterAction? {
        let target = bindingContext.current.target(elementID: control.neutralElementID, facetID: layer.rawValue,
                                                   inputKind: CompactBindingKey.kinds(control)[0])
        let action = target.flatMap(Int.init).flatMap { configuration.assignments.indices.contains($0) ? configuration.assignments[$0].action : nil }
        #if DEBUG
            bindingReference?.lookup(control, layer: layer, target: target, action: action)
        #endif
        return action
    }

    @discardableResult public mutating func set(_ id: String, value: Double, fromAgent: Bool = false, writer: ParameterWriter? = nil) throws -> Double {
        guard let definition = definition(id) else { throw ParameterError.unknownParameter(id) }
        try validateWrite(id, writer: writer ?? (fromAgent ? .remote : .interface))
        guard !fromAgent || (definition.agentWritable && definition.externallyProtected != true) else { throw ParameterError.agentDenied(id) }
        let normalized = try definition.normalized(value)
        values[id] = normalized
        return normalized
    }

    /// Returns a neutral action intent; the host owns plugin lifecycle.
    public mutating func receive(_ event: CompactInput, writer: ParameterWriter = .hardware) throws -> ActionReference? {
        guard let action = assignment(event.control, layer: event.layer) else { return nil }
        switch action {
        case .runMacro:
            // Session orchestration owns guarded parameter writes, links and history.
            throw ParameterError.invalidAssignment
        case let .parameter(id):
            guard let definition = definition(id) else { throw ParameterError.unknownParameter(id) }
            if event.isPressed == false {
                return nil
            }
            let value = event.isPressed == true ? ((values[id] ?? definition.minimum) == definition.minimum ? definition.maximum : definition.minimum)
                : definition.minimum + Double(event.value) / 127 * (definition.maximum - definition.minimum)
            try set(id, value: value, writer: writer)
        case let .agent(slot):
            guard event.isPressed == true else { return nil }
            guard let ref = actionBindings[slot] else { throw ParameterError.invalidAssignment }
            return ref
        case let .resetGroup(group):
            guard event.isPressed == true else { return nil }
            for p in configuration.parameters where p.group == group {
                try set(p.id, value: p.defaultValue, writer: writer)
            }
        case let .step(id, step):
            if event.isPressed == true {
                try set(id, value: (values[id] ?? 0) + step, writer: writer)
            }
        case let .set(id, value):
            if event.isPressed == true {
                try set(id, value: value, writer: writer)
            }
        case let .cycle(id, choices):
            if event.isPressed == true {
                guard let definition = definition(id) else { throw ParameterError.unknownParameter(id) }
                let normalized = try choices.map { try definition.normalized($0) }
                let next = normalized.firstIndex(of: values[id] ?? .nan).map { ($0 + 1) % normalized.count } ?? 0
                try set(id, value: normalized[next], writer: writer)
            }
        }
        return nil
    }
}
