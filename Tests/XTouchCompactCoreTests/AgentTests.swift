import Testing
@testable import XTouchCompactCore

@Test func mockAgentsRequireApprovalAndEncodeBothLEDModes() throws {
    var agents = MockAgents()
    agents.primary(1, now: 10)
    agents.advance(to: 11.9)
    #expect(agents.slots[0].phase == .running)
    agents.advance(to: 12)
    #expect(agents.slots[0].phase == .waitingApproval)
    agents.advance(to: 100)
    #expect(agents.slots[0].phase == .waitingApproval)
    for variant in [ButtonLightProtocol.manual, .observed114] {
        var session = try CompactSession(map: FactoryStandardMap(globalReceiveChannel: 3), lightProtocol: variant)
        let feedback = try session.agentFeedback(agents)
        #expect(feedback.contains(.noteOn(channel: 3, number: 0, velocity: variant.velocity(for: .blink))))
        #expect(!feedback.contains {
            if case let .controlChange(_, n, _) = $0 {
                return (1 ... 9).contains(n)
            }; return false
        })
    }
    agents.primary(1, now: 100)
    agents.advance(to: 102)
    #expect(agents.slots[0].phase == .completed)
    agents.primary(2, now: 103)
    agents.primary(2, now: 104)
    #expect(agents.slots[1].phase == .interrupted)
}
