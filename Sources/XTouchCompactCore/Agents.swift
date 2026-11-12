import AgentPlugin
import AgentRemoteBinding
import Foundation

/// Read-only host presentation. The shared plugin owns every lifecycle transition.
public typealias AgentPhase = AgentRunState
public struct AgentSlot: Identifiable, Equatable, Sendable {
    public let id: Int
    public let phase: AgentPhase
    public let progress: Double
    public let statusKey: String
    public var primaryActionLabelKey: String {
        switch phase { case .waitingApproval: "Approve"; case .queued, .running: "Interrupt"; default: "Start" }
    }

    public var light: ButtonLight {
        IndicatorPresentation.light(.init(semantic: phase.indicatorSemantic))
    }

    public init(id: Int, phase: AgentPhase, progress: Double = 0, statusKey: String = "") {
        self.id = id; self.phase = phase; self.progress = progress; self.statusKey = statusKey
    }
}

public struct AgentPresentation: Equatable, Sendable {
    public let slots: [AgentSlot]
    public init(_ host: CompactPluginHost) {
        slots = host.binding(AgentRemoteBinding.defaultInstanceID, as: AgentRemoteBinding.self)?.plugin.slots.map {
            AgentSlot(id: $0.id, phase: $0.state, progress: $0.progress, statusKey: $0.statusKey)
        } ?? []
    }
}
