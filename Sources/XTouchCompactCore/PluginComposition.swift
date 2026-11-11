import AgentRemoteBinding
import ChassisPlugin
import ChassisRemoteBinding
import ExampleParameterSets
import Foundation
import OutputRemoteBinding
import ParameterOutputPlugin
import RemoteToolContracts
import RobotPlugin
import RobotRemoteBinding
import SurfacePluginContracts

public enum OptionalBusinessPlugin: String, CaseIterable, Sendable { case robot, chassis, output }

/// Explicit static composition. Nothing here changes control assignments or recalls motors.
public extension CompactPluginHost {
    mutating func installOptional(_ selection: Set<OptionalBusinessPlugin>, lifetimeID: String, at time: PluginTime) throws {
        var bindings: [any RemoteBinding] = []
        if selection.contains(.robot) {
            try bindings.append(RobotRemoteBinding(instanceID: "robot", plugin: RobotPlugin(instanceID: lifetimeID + ".robot")))
        }
        if selection.contains(.chassis) {
            try bindings.append(ChassisRemoteBinding(instanceID: "chassis", plugin: ChassisPlugin(instanceID: lifetimeID + ".chassis")))
        }
        if selection.contains(.output) {
            let output = try ParameterOutputPlugin(limits: [.init(id: "output.value", minimum: 0, maximum: 1, maximumChange: 0.1, maximumVelocity: 0.25)], precision: .float32)
            bindings.append(OutputRemoteBinding(instanceID: "output", plugin: output))
        }
        try registerBindings(bindings, at: time)
    }

    static func referenceArmParameters() throws -> [ParameterDefinition] {
        try ExampleParameterSets.referenceArm().map { p in
            .init(id: p.id.rawValue, name: p.nameKey, group: p.group, unit: p.unit, minimum: p.minimum,
                  maximum: p.maximum, defaultValue: p.defaultValue, step: p.step ?? 0,
                  isSwitch: p.kind == .toggle, agentWritable: p.agentWritable,
                  externallyProtected: p.externallyProtected ? true : nil)
        }
    }
}

public struct BusinessPluginPresentation: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let state: String
    public let detail: String?
}

public extension CompactPluginHost {
    var businessPresentations: [BusinessPluginPresentation] {
        var result: [BusinessPluginPresentation] = []
        if let binding = binding("robot", as: RobotRemoteBinding.self) {
            let state = binding.plugin.simulator.snapshot()
            result.append(.init(id: "robot", title: "Reference robot (simulation)", state: state.metadata.state,
                                detail: state.actual.map { $0.joints_rad.map { String(format: "%.3f", $0) }.joined(separator: ", ") }))
        }
        if let binding = binding("chassis", as: ChassisRemoteBinding.self) {
            let state = binding.plugin.simulator.snapshot()
            result.append(.init(id: "chassis", title: "Ackermann chassis (simulation)", state: state.metadata.state,
                                detail: state.actual.map { $0.pose_m_rad.map { String(format: "%.3f", $0) }.joined(separator: ", ") }))
        }
        if let binding = binding("output", as: OutputRemoteBinding.self) {
            result.append(.init(id: "output", title: "Parameter output", state: binding.plugin.gate.status.rawValue, detail: nil))
        }
        return result
    }
}
