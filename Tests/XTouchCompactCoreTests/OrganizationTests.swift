import Foundation
import Testing
@testable import XTouchCompactCore

private func motors(_ messages: [MIDIMessage]) -> [MIDIMessage] {
    messages.filter {
        if case let .controlChange(_, n, _) = $0 {
            return (1 ... 9).contains(n)
        }
        return false
    }
}

/// Order-independent comparison of message lists (MIDIMessage is not Hashable).
private func sameMessages(_ a: [MIDIMessage], _ b: [MIDIMessage]) -> Bool {
    a.count == b.count && a.allSatisfy { b.contains($0) } && b.allSatisfy { a.contains($0) }
}

private func linked(_ members: [String] = ["a.Fader.2", "a.Fader.3"]) -> SurfaceConfiguration {
    var config = SurfaceConfiguration.neutral
    config.links = [ParameterLink(id: "vca", name: "VCA 1", leader: "a.Fader.1", members: members)]
    return config
}

@Test func colorsLinksAndScenesRoundTripAndOlderFilesStillLoad() throws {
    var config = linked()
    config.parameters[0].color = .teal
    config.scenes = [ParameterScene(id: "s1", name: "Intro", values: ["a.Fader.1": 10])]
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(SurfaceConfiguration.self, from: data)
    #expect(decoded == config)
    try decoded.validate()
    // A file written before these fields existed decodes with nil and validates.
    var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(SurfaceConfiguration.neutral)) as? [String: Any])
    legacy.removeValue(forKey: "links"); legacy.removeValue(forKey: "scenes")
    let old = try JSONDecoder().decode(SurfaceConfiguration.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(old.links == nil && old.scenes == nil && old.parameters[0].color == nil)
    try old.validate()
}

@Test func invalidLinksAndScenesAreRejected() {
    let bad: [[ParameterLink]] = [
        [ParameterLink(id: "x", name: "X", leader: "missing", members: ["a.Fader.2"])],
        [ParameterLink(id: "x", name: "X", leader: "a.Fader.1", members: [])],
        [ParameterLink(id: "x", name: "X", leader: "a.Fader.1", members: ["a.Fader.1"])],
        [ParameterLink(id: "x", name: " ", leader: "a.Fader.1", members: ["a.Fader.2"])],
        [ParameterLink(id: "x", name: "X", leader: "a.Fader.1", members: ["a.Fader.2", "a.Fader.2"])],
        // A follower cannot have two leaders, and a follower cannot lead (no chains or loops).
        [ParameterLink(id: "x", name: "X", leader: "a.Fader.1", members: ["a.Fader.3"]),
         ParameterLink(id: "y", name: "Y", leader: "a.Fader.2", members: ["a.Fader.3"])],
        [ParameterLink(id: "x", name: "X", leader: "a.Fader.1", members: ["a.Fader.2"]),
         ParameterLink(id: "y", name: "Y", leader: "a.Fader.2", members: ["a.Fader.3"])],
        [ParameterLink(id: "x", name: "X", leader: "a.Fader.1", members: ["a.Fader.2"]),
         ParameterLink(id: "x", name: "Y", leader: "a.Fader.4", members: ["a.Fader.5"])],
    ]
    for links in bad {
        var config = SurfaceConfiguration.neutral
        config.links = links
        #expect(throws: ParameterError.self) { try config.validate() }
    }
    for scene in [ParameterScene(id: "", name: "S", values: [:]), ParameterScene(id: "s", name: "", values: [:]),
                  ParameterScene(id: "s", name: "S", values: ["missing": 1]), ParameterScene(id: "s", name: "S", values: ["a.Fader.1": .nan])]
    {
        var config = SurfaceConfiguration.neutral
        config.scenes = [scene]
        #expect(throws: ParameterError.self) { try config.validate() }
    }
}

@Test func linkedMembersFollowTheLeaderByRelativeChangeAndClamp() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.loadConfiguration(linked())
    _ = try session.connect()
    _ = try session.setParameter("a.Fader.2", value: 20)
    _ = try session.setParameter("a.Fader.3", value: 120)
    let messages = try session.setParameter("a.Fader.1", value: 30) // Leader +30 on a 0…127 range.
    #expect(session.parameters.values["a.Fader.2"] == 50)
    #expect(session.parameters.values["a.Fader.3"] == 127) // Clamped at its own maximum.
    #expect(sameMessages(motors(messages), [.controlChange(channel: 0, number: 1, value: 30),
                                            .controlChange(channel: 0, number: 2, value: 50),
                                            .controlChange(channel: 0, number: 3, value: 127)]))
    // Members never move the leader or each other.
    _ = try session.setParameter("a.Fader.2", value: 0)
    #expect(session.parameters.values["a.Fader.1"] == 30)
    #expect(session.parameters.values["a.Fader.3"] == 127)
}

@Test func linkedMotorsRespectTouchAndAgentPermission() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    var config = linked()
    config.parameters[1].agentWritable = false // a.Fader.2 refuses Agent writes.
    _ = try session.loadConfiguration(config)
    _ = try session.connect()
    _ = try session.receive([.controlChange(channel: 0, number: 103, value: 127)]) // Hand on fader 3.
    let messages = try session.setParameter("a.Fader.1", value: 40, fromAgent: true, drivesMotors: true)
    #expect(session.parameters.values["a.Fader.2"] == 0) // Agent cannot move a protected member.
    #expect(session.parameters.values["a.Fader.3"] == 40)
    #expect(session.state.isMotorPending(3)) // Touched member defers instead of fighting the hand.
    #expect(!motors(messages).contains {
        if case .controlChange(_, 3, _) = $0 {
            true
        } else {
            false
        }
    })
    // Without motor permission, neither the leader nor any member is commanded or queued.
    let quiet = try session.setParameter("a.Fader.1", value: 60, fromAgent: true, drivesMotors: false)
    #expect(motors(quiet).isEmpty)
    #expect(!session.state.isMotorPending(3))
    #expect(session.parameters.values["a.Fader.3"] == 60)
}

@Test func physicalLeaderPropagatesOnlyWhileTouched() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.loadConfiguration(linked(["a.Fader.2"]))
    _ = try session.connect()
    // An untouched position report may be motor progress: it never leads the link.
    var update = try session.receive([.controlChange(channel: 0, number: 1, value: 50)])
    #expect(session.parameters.values["a.Fader.2"] == 0)
    #expect(motors(update.feedback).isEmpty)
    _ = try session.receive([.controlChange(channel: 0, number: 101, value: 127)])
    update = try session.receive([.controlChange(channel: 0, number: 1, value: 70)])
    #expect(session.parameters.values["a.Fader.2"] == 20)
    #expect(motors(update.feedback) == [.controlChange(channel: 0, number: 2, value: 20)]) // Never the leader's own motor.
}

@Test func undoCoalescesADragAndRedoRestores() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.loadConfiguration(linked(["a.Fader.2"]))
    _ = try session.connect()
    #expect(!session.canUndo)
    _ = try session.receive([.controlChange(channel: 0, number: 101, value: 127)])
    for raw: UInt8 in [10, 20, 30] {
        _ = try session.receive([.controlChange(channel: 0, number: 1, value: raw)])
    }
    _ = try session.receive([.controlChange(channel: 0, number: 101, value: 0)])
    _ = try session.setParameter("a.Encoder.1", value: 64)
    #expect(try session.undo().contains(.controlChange(channel: 0, number: 26, value: 1)))
    #expect(session.parameters.values["a.Encoder.1"] == 0)
    let messages = try session.undo() // The whole drag, including the linked member, is one step.
    #expect(session.parameters.values["a.Fader.1"] == 0 && session.parameters.values["a.Fader.2"] == 0)
    #expect(sameMessages(motors(messages), [.controlChange(channel: 0, number: 1, value: 0), .controlChange(channel: 0, number: 2, value: 0)]))
    #expect(!session.canUndo && session.canRedo)
    _ = try session.redo()
    #expect(session.parameters.values["a.Fader.1"] == 30 && session.parameters.values["a.Fader.2"] == 30)
    _ = try session.setParameter("a.Fader.4", value: 5)
    #expect(!session.canRedo) // A new change clears redo.
    _ = try session.loadConfiguration(session.parameters.configuration, resetValues: true)
    #expect(!session.canUndo)
}

@Test func undoKeepsTouchDeferralAndHistoryIsBounded() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.connect()
    _ = try session.setParameter("a.Fader.1", value: 90)
    _ = try session.receive([.controlChange(channel: 0, number: 101, value: 127)])
    #expect(try motors(session.undo()).isEmpty)
    #expect(session.state.isMotorPending(1))
    for value in 0 ..< (CompactSession.undoLimit + 10) {
        _ = try session.setParameter("a.Encoder.1", value: Double(value % 127 + 1))
    }
    var steps = 0
    while session.canUndo {
        _ = try session.undo(); steps += 1
    }
    #expect(steps == CompactSession.undoLimit)
}

@Test func scenesCaptureRecallAsOneUndoStepWithoutMotors() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.connect()
    _ = try session.setParameter("a.Fader.1", value: 100)
    _ = try session.setParameter("a.Encoder.2", value: 127)
    try session.captureScene(id: "s1", name: "Loud")
    #expect(session.parameters.configuration.scenes?.first?.values["a.Fader.1"] == 100)
    _ = try session.setParameter("a.Fader.1", value: 0)
    _ = try session.setParameter("a.Encoder.2", value: 0)
    let messages = try session.recallScene(id: "s1")
    #expect(session.parameters.values["a.Fader.1"] == 100 && session.bank(.a).faders[0] == 100)
    #expect(motors(messages).isEmpty) // Rings and LEDs follow; motors wait for explicit recall.
    #expect(messages.contains(.controlChange(channel: 0, number: 27, value: 13)))
    #expect(!session.state.isMotorPending(1))
    #expect(try motors(session.recallFaders()).contains(.controlChange(channel: 0, number: 1, value: 100)))
    _ = try session.undo()
    #expect(session.parameters.values["a.Fader.1"] == 0 && session.parameters.values["a.Encoder.2"] == 0)
    try session.captureScene(id: "s1", name: "Quiet") // Same ID replaces.
    #expect(session.parameters.configuration.scenes?.count == 1)
    #expect(session.parameters.configuration.scenes?.first?.name == "Quiet")
    try session.deleteScene(id: "s1")
    #expect(session.parameters.configuration.scenes?.isEmpty == true)
    #expect(throws: ParameterError.self) { _ = try session.recallScene(id: "s1") }
    #expect(throws: ParameterError.self) { try session.captureScene(id: "s2", name: " ") }
}

@Test func consecutiveEditsOfOneControlAreOneUndoStep() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.connect()
    for value: UInt8 in [10, 20, 30, 40] {
        _ = try session.setEncoder(1, value: value)
    } // Knob ticks.
    for value: UInt8 in [5, 6, 7] {
        _ = try session.setFader(2, value: value)
    } // Slider drag.
    _ = try session.undo()
    #expect(session.parameters.values["a.Fader.2"] == 0 && session.parameters.values["a.Encoder.1"] == 40)
    _ = try session.undo()
    #expect(session.parameters.values["a.Encoder.1"] == 0)
    #expect(!session.canUndo)
}

@Test func linkedInputBatchCannotEmitMotorsAfterLaterTouchOrLayerMismatch() throws {
    for finalInput in [MIDIMessage.controlChange(channel: 0, number: 102, value: 127),
                       .controlChange(channel: 0, number: 37, value: 42)]
    {
        var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
        _ = try session.loadConfiguration(linked(["a.Fader.2"]))
        _ = try session.connect()
        let update = try session.receive([.controlChange(channel: 0, number: 101, value: 127),
                                          .controlChange(channel: 0, number: 1, value: 60), finalInput])
        #expect(motors(update.feedback).isEmpty)
        if session.state.isTouched(2) {
            #expect(session.state.isMotorPending(2))
            let release = try session.receive([.controlChange(channel: 0, number: 102, value: 0)])
            #expect(motors(release.feedback) == [.controlChange(channel: 0, number: 2, value: 60)])
        } else {
            #expect(session.state.layerMismatch)
            #expect(!session.state.isMotorPending(2))
        }
    }
}

@Test func laterPhysicalFollowerInputRevokesEarlierGeneratedMotorAuthority() throws {
    for held in [false, true] {
        var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
        _ = try session.loadConfiguration(linked(["a.Fader.2"]))
        _ = try session.connect()
        var messages: [MIDIMessage] = [.controlChange(channel: 0, number: 101, value: 127),
                                       .controlChange(channel: 0, number: 1, value: 60)]
        if held {
            messages.append(.controlChange(channel: 0, number: 102, value: 127))
        }
        messages.append(.controlChange(channel: 0, number: 2, value: 90))
        let update = try session.receive(messages)
        #expect(motors(update.feedback).isEmpty)
        #expect(!session.state.isMotorPending(2))
        #expect(session.bank(.a).faders[1] == 90)
        #expect(try motors(session.receive([.controlChange(channel: 0, number: 102, value: 0)]).feedback).isEmpty)
    }
}

@Test func motorlessWriteRevokesAnAlreadyGeneratedFeedbackBatch() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    let old = try session.setFader(1, value: 40)
    _ = try session.setParameter("a.Fader.1", value: 90, drivesMotors: false)
    #expect(session.filterFeedbackForDelivery(old).isEmpty)
    #expect(!session.state.isMotorPending(1))
}
