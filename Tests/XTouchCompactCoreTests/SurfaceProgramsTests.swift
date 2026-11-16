import Foundation
import Testing
@testable import XTouchCompactCore

private func macroSession(_ actions: [ParameterMutation]) throws -> CompactSession {
    var config = SurfaceConfiguration.neutral
    config.macros = [.init(id: "m", name: "Cue", actions: actions)]
    config.assignments.append(.init(control: .button(9), layer: .a, action: .runMacro("m")))
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.loadConfiguration(config)
    return session
}

@Test func macrosExecuteInOrderWithOneUndoAndDebouncePhysicalPresses() throws {
    var session = try macroSession([.set("a.Fader.1", 20), .step("a.Fader.1", 5), .toggle("a.Encoder.1")])
    _ = try session.activateButton(9)
    #expect(session.parameters.values["a.Fader.1"] == 25)
    #expect(session.parameters.values["a.Encoder.1"] == 127)
    _ = try session.undo()
    #expect(session.parameters.values["a.Fader.1"] == 0 && session.parameters.values["a.Encoder.1"] == 0)
    #expect(!session.canUndo)
    _ = try session.redo()
    #expect(session.parameters.values["a.Fader.1"] == 25)
    var incremental = try macroSession([.step("a.Fader.1", 1)])
    let press = MIDIMessage.noteOn(channel: 0, number: 24, velocity: 127)
    _ = try incremental.receive([press, press])
    #expect(incremental.parameters.values["a.Fader.1"] == 1)
    _ = try incremental.receive([.noteOff(channel: 0, number: 24, velocity: 0), press])
    #expect(incremental.parameters.values["a.Fader.1"] == 2)
}

@Test func macrosReuseTouchLinkPermissionsAndContinueAfterRejectedSteps() throws {
    for motors in [false, true] {
        var session = try macroSession([.set("a.Fader.3", 90), .set("a.Fader.1", 40), .step("a.Fader.1", 10)])
        var config = session.parameters.configuration
        config.links = [.init(id: "link", name: "Pair", leader: "a.Fader.1", members: ["a.Fader.2"])]
        config.parameters[2].agentWritable = false
        _ = try session.loadConfiguration(config)
        session.setSafetyTouch(1, touched: true)
        let feedback = try session.runMacro("m", fromAgent: true, drivesMotors: motors)
        #expect(session.parameters.values["a.Fader.3"] == 0)
        #expect(session.parameters.values["a.Fader.1"] == 50 && session.parameters.values["a.Fader.2"] == 50)
        #expect(session.lastMacroExecution?.steps[0].outcome == .rejected)
        #expect(session.lastMacroExecution?.steps[1].outcome == (motors ? .deferred : .withheld))
        #expect(!feedback.contains {
            if case .controlChange(_, 1, _) = $0 {
                return true
            }; return false
        })
        if !motors {
            #expect(!feedback.contains {
                if case .controlChange(_, 2, _) = $0 {
                    return true
                }; return false
            })
            #expect(!session.state.isMotorPending(1) && !session.state.isMotorPending(2))
        }
        _ = try session.undo()
        #expect(session.parameters.values["a.Fader.1"] == 0 && session.parameters.values["a.Fader.2"] == 0)
    }
}

@Test func macroDefinitionsValidateBoundsTargetsAndRoundTripWithConfiguration() throws {
    let valid = try macroSession([.set("a.Fader.1", 500), .resetGroup("Layer A")]).parameters.configuration
    #expect(try JSONDecoder().decode(SurfaceConfiguration.self, from: JSONEncoder().encode(valid)) == valid)
    for actions: [ParameterMutation] in [[], Array(repeating: .set("a.Fader.1", 1), count: 65), [.step("a.Fader.1", 0)], [.toggle("missing")], [.set("a.Fader.1", .infinity)], [.resetGroup("missing")]] {
        var invalid = valid; invalid.macros = [.init(id: "m", name: "Cue", actions: actions)]
        #expect(throws: ParameterError.self) { try invalid.validate() }
    }
    var session = try macroSession([.set("a.Fader.1", 500), .resetGroup("Layer A")])
    _ = try session.runMacro("m")
    #expect(session.parameters.values["a.Fader.1"] == 0)
    #expect(session.lastMacroExecution?.steps.count == 2)
}

@Test func macroAssignedToTouchStillReconcilesOnlyOnRealRelease() throws {
    var session = try macroSession([.set("a.Fader.1", 90)])
    var config = session.parameters.configuration
    config.assignments.append(.init(control: .faderTouch(1), layer: .a, action: .runMacro("m")))
    _ = try session.loadConfiguration(config)
    let held = try session.receive([.controlChange(channel: 0, number: 101, value: 127)])
    #expect(session.state.isMotorPending(1))
    #expect(!held.feedback.contains {
        if case .controlChange(_, 1, _) = $0 {
            return true
        }; return false
    })
    let release = try session.receive([.controlChange(channel: 0, number: 101, value: 0)])
    #expect(release.feedback.contains(.controlChange(channel: 0, number: 1, value: 90)))
}
