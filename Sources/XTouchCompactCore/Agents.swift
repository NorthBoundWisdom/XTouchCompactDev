import Foundation

public enum AgentPhase: String, Codable, Sendable { case idle, running, waitingApproval, completed, interrupted }
public struct AgentSlot: Identifiable, Equatable, Sendable {
    public let id: Int
    public var phase: AgentPhase = .idle
    public var changedAt: TimeInterval = 0
    public var approved = false
    public var light: ButtonLight {
        switch phase { case .running: .on; case .waitingApproval: .blink; default: .off }
    }
}

public struct MockAgents: Equatable, Sendable {
    public private(set) var slots = (1 ... 8).map { AgentSlot(id: $0) }
    public init() {}
    public mutating func primary(_ slot: Int, now: TimeInterval) {
        guard (1 ... 8).contains(slot), now.isFinite else { return }
        let index = slot - 1
        switch slots[index].phase {
        case .idle, .completed, .interrupted:
            slots[index].phase = .running; slots[index].approved = false
        case .running: slots[index].phase = .interrupted
        case .waitingApproval: slots[index].phase = .running; slots[index].approved = true
        }
        slots[index].changedAt = now
    }

    public mutating func advance(to now: TimeInterval) {
        guard now.isFinite else { return }
        for index in slots.indices where slots[index].phase == .running && now - slots[index].changedAt >= 2 {
            slots[index].phase = slots[index].approved ? .completed : .waitingApproval
            slots[index].changedAt = now
        }
    }
}

public extension CompactSession {
    mutating func agentFeedback(_ agents: MockAgents) throws -> [MIDIMessage] {
        try updateAgentLights(Dictionary(uniqueKeysWithValues: agents.slots.map { ($0.id, $0.light) }))
    }
}
