import AgentPlugin
import AgentRemoteBinding
import Foundation
import RemoteToolContracts
import SurfacePluginContracts

public enum PluginHostError: Error, Equatable, Sendable {
    case duplicatePlugin, invalidContract, invalidDescriptor, unknownPlugin, invalidAction, invalidUpdate
}

/// A host-local value adapter. RemoteRegistry owns each plugin exactly once.
/// Validate the entire candidate before making any registration or update visible.
public struct CompactPluginHost: Sendable {
    private var registry = try! RemoteRegistry(epoch: UUID().uuidString)
    private var installed: [String: PluginManifest] = [:]
    private var feedbackInstances: [String] = []
    public var feedbackIndicators: [IndicatorID: IndicatorState] {
        feedbackInstances.reduce(into: [:]) { result, id in
            if let snapshot = registry.snapshot(instanceID: id) {
                result.merge(snapshot.indicators) { _, new in new }
            }
        }
    }

    public private(set) var parameterValues: [String: [ParameterID: Double]] = [:]
    public init() {}
    public var instanceIDs: [String] {
        installed.keys.sorted()
    }

    public var manifests: [PluginManifest] {
        instanceIDs.map { installed[$0]! }
    }

    public var snapshots: [String: PluginSnapshot] {
        Dictionary(uniqueKeysWithValues: instanceIDs.compactMap { id in registry.snapshot(instanceID: id).map { (id, $0) } })
    }

    public func binding<P: RemoteBinding>(_ id: String, as type: P.Type) -> P? {
        registry.binding(id, as: type)
    }

    /// Plugins without remote tools still use the same value registry.
    public mutating func register(_ candidates: [any ControlPlugin], at time: PluginTime) throws {
        try registerBindings(candidates.map { LocalBinding(plugin: $0) }, at: time)
    }

    public mutating func registerBindings(_ candidates: [any RemoteBinding], at time: PluginTime) throws {
        var next = self
        var instances = Set(installed.keys)
        for binding in candidates {
            guard !binding.instanceID.isEmpty, instances.insert(binding.instanceID).inserted else { throw PluginHostError.duplicatePlugin }
            guard binding.manifest.contractVersion == "1.0" else { throw PluginHostError.invalidContract }
        }
        // The shared registry validates all declarations atomically before any .start.
        // This also keeps namespace and collision rules identical between both hosts.
        do { try next.registry.install(candidates) }
        catch { throw PluginHostError.invalidDescriptor }
        for binding in candidates {
            let id = binding.instanceID
            next.parameterValues[id] = try Dictionary(uniqueKeysWithValues: binding.surface.parameters.map { try ($0.id, $0.clamp($0.defaultValue)) })
            next.installed[id] = binding.manifest
            let update = try next.registry.handle(instanceID: id, input: .start, at: time)
            try next.accept(update, from: id)
        }
        self = next
    }

    @discardableResult public mutating func handle(_ input: PluginInput, pluginID: PluginID, at time: PluginTime) throws -> PluginUpdate {
        let matches = installed.filter { $0.value.id == pluginID }
        guard matches.count == 1, let id = matches.keys.first else { throw PluginHostError.unknownPlugin }
        return try handle(input, instanceID: id, at: time)
    }

    @discardableResult public mutating func handle(_ input: PluginInput, instanceID: String, at time: PluginTime) throws -> PluginUpdate {
        guard let manifest = installed[instanceID], let surface = registry.surface(instanceID: instanceID) else { throw PluginHostError.unknownPlugin }
        if case let .invoke(ref, _) = input {
            guard ref.pluginID == manifest.id, let action = surface.actions.first(where: { $0.id == ref.actionID }),
                  action.indexCount.map({ count in ref.index.map { (1 ... count).contains($0) } ?? false }) ?? (ref.index == nil) else { throw PluginHostError.invalidAction }
        }
        var next = self
        let update = try next.registry.handle(instanceID: instanceID, input: input, at: time)
        try next.accept(update, from: instanceID)
        self = next
        return update
    }

    public mutating func advance(to time: PluginTime) throws {
        var next = self
        for id in instanceIDs {
            try next.handle(.advance, instanceID: id, at: time)
        }
        self = next
    }

    private mutating func accept(_ update: PluginUpdate, from id: String) throws {
        guard let surface = registry.surface(instanceID: id),
              Set(update.indicators.keys).isSubset(of: Set(surface.indicators.map(\.id))),
              update.indicators.values.allSatisfy({ $0.progress.map { $0.isFinite && (0 ... 1).contains($0) } ?? true }) else { throw PluginHostError.invalidUpdate }
        for write in update.parameterWrites {
            guard let p = surface.parameters.first(where: { $0.id == write.id }) else { throw PluginHostError.invalidUpdate }
            parameterValues[id, default: [:]][write.id] = try p.clamp(write.value)
        }
    }

    public var remoteTools: [RemoteToolDescriptor] {
        registry.tools
    }

    public mutating func callRemote(_ name: String, arguments: JSONValue, context: RemoteCallContext) throws -> JSONValue {
        var next = self
        let response = try next.registry.call(name, arguments: arguments, context: context)
        self = next
        return response
    }

    public mutating func replaceBinding(_ binding: any RemoteBinding, at time: PluginTime, event: PluginEvent?) throws {
        var next = self
        try next.registry.replace(binding, at: time, event: event)
        self = next
    }

    public static func agent(at time: PluginTime = 0) throws -> Self {
        var host = Self()
        try host.registerBindings([AgentRemoteBinding(instanceID: AgentRemoteBinding.defaultInstanceID, plugin: AgentPlugin(approvalPolicy: .localOrigins, at: time))], at: time)
        host.feedbackInstances = [AgentRemoteBinding.defaultInstanceID]
        return host
    }
}

private struct LocalBinding: RemoteBinding {
    var plugin: any ControlPlugin
    var instanceID: String {
        plugin.manifest.id.rawValue
    }

    var manifest: PluginManifest {
        plugin.manifest
    }

    var surface: SurfaceDescriptor {
        plugin.surface
    }

    var tools: [RemoteToolDescriptor] {
        []
    }

    func snapshot() -> PluginSnapshot {
        plugin.snapshot()
    }

    mutating func handle(_ input: PluginInput, at time: PluginTime) throws -> PluginUpdate {
        try plugin.handle(input, at: time)
    }

    mutating func call(_: String, arguments _: JSONValue, context _: RemoteCallContext) throws -> JSONValue {
        throw PluginError(code: .unsupported)
    }
}

/// Version-1 .agent bindings are translated only at this configuration adapter.
public enum PluginConfigurationAdapter {
    public static func agentAction(_ slot: Int) -> ActionReference {
        .init(pluginID: AgentPlugin.pluginID, actionID: AgentPlugin.primaryActionID, index: slot)
    }

    public static var agentActions: [Int: ActionReference] {
        Dictionary(uniqueKeysWithValues: (1 ... 8).map { ($0, agentAction($0)) })
    }

    public static var agentIndicators: [Int: IndicatorID] {
        Dictionary(uniqueKeysWithValues: (1 ... 8).map { ($0, AgentPlugin.indicatorID(for: $0)) })
    }
}

public enum IndicatorPresentation {
    public static func light(_ state: IndicatorState) -> ButtonLight {
        switch state.semantic { case .active: .on; case .attention: .blink; default: .off }
    }
}
