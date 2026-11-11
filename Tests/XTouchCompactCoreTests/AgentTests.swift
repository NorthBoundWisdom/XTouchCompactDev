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

@Test func actionLEDsNeverLatchAndAgentLightsSurviveBoundaries() throws {
    for variant in [ButtonLightProtocol.manual, .observed114] {
        var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: variant)
        var agents = MockAgents()
        agents.primary(1, now: 0)
        #expect(try session.agentFeedback(agents).contains(.noteOn(channel: 0, number: 0, velocity: variant.velocity(for: .on))))
        agents.advance(to: 2)
        _ = try session.agentFeedback(agents)
        let approval = try session.receive([.noteOn(channel: 0, number: 16, velocity: 127)])
        #expect(!approval.feedback.contains(.noteOn(channel: 0, number: 0, velocity: 0)))
        agents.primary(1, now: 2)
        #expect(try session.agentFeedback(agents).contains(.noteOn(channel: 0, number: 0, velocity: variant.velocity(for: .on))))
        for feedback in try [session.selectLayer(.b), session.connect(), session.reconfigure(map: FactoryStandardMap(), lightProtocol: variant), session.loadConfiguration(.neutral)] {
            #expect(feedback.contains(.noteOn(channel: 0, number: 0, velocity: variant.velocity(for: .on))))
            #expect(!feedback.contains {
                if case let .controlChange(_, number, _) = $0 {
                    return (1 ... 9).contains(number)
                }; return false
            })
            #expect(!feedback.contains(.noteOn(channel: 0, number: 0, velocity: 0)))
        }
        let unassigned = try session.receive([.noteOn(channel: 0, number: 109, velocity: 127)])
        #expect(!unassigned.feedback.contains(.noteOn(channel: 0, number: 38, velocity: variant.velocity(for: .on))))
    }
}

@Test func stepSetCycleAndResetButtonsDoNotLatchLEDs() throws {
    var config = SurfaceConfiguration.neutral
    let actions: [ParameterAction] = [.step("a.Fader.1", 1), .set("a.Fader.1", 30), .cycle("a.Fader.1", [0, 50]), .resetGroup("Layer A")]
    for (offset, action) in actions.enumerated() {
        let index = offset + 2
        config.assignments.removeAll { $0.control == .button(index) && $0.layer == .a }
        config.assignments.append(.init(control: .button(index), layer: .a, action: action))
    }
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.loadConfiguration(config)
    for index in 2 ... 5 {
        let pressed = try session.receive([.noteOn(channel: 0, number: UInt8(15 + index), velocity: 127)])
        #expect(!pressed.feedback.contains(.noteOn(channel: 0, number: UInt8(index - 1), velocity: 1)))
        #expect(!session.bank(.a).buttons[index - 1])
    }
}

@Test func agentLightStatesOnlyAffectCurrentlyBoundLayerButtons() throws {
    #expect(AgentSlot(id: 1, phase: .idle).light == .off)
    #expect(AgentSlot(id: 1, phase: .completed).light == .off)
    #expect(AgentSlot(id: 1, phase: .interrupted).light == .off)
    #expect(AgentSlot(id: 1, phase: .running).light == .on)
    #expect(AgentSlot(id: 1, phase: .waitingApproval).light == .blink)
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    var config = SurfaceConfiguration(parameters: [], assignments: [
        .init(control: .button(12), layer: .a, action: .agent(1)),
        .init(control: .button(23), layer: .b, action: .agent(1)),
    ])
    _ = try session.loadConfiguration(config)
    let a = try session.updateAgentLights([1: .blink])
    #expect(a.contains(.noteOn(channel: 0, number: 11, velocity: 2)))
    #expect(!a.contains(.noteOn(channel: 0, number: 22, velocity: 2)))
    let b = try session.selectLayer(.b)
    #expect(b.contains(.noteOn(channel: 0, number: 22, velocity: 2)))
    config.assignments.removeAll()
    let cleared = try session.loadConfiguration(config)
    #expect(cleared.contains(.noteOn(channel: 0, number: 22, velocity: 0)))
}
