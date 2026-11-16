import AgentPlugin
import AgentRemoteBinding
import Foundation
import SurfacePluginContracts

public extension CompactPluginHost {
    static func agent(at time: PluginTime = 0) throws -> Self {
        var host = Self()
        try host.registerBindings([AgentRemoteBinding(instanceID: AgentRemoteBinding.defaultInstanceID, plugin: AgentPlugin(approvalPolicy: .localOrigins, at: time))], at: time)
        host.configureFeedbackInstances([AgentRemoteBinding.defaultInstanceID])
        return host
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
