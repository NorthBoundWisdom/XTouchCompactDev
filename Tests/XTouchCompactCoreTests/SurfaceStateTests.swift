import Testing
@testable import XTouchCompactCore

@Test func noMotorDriveWhileUserTouchesFader() throws {
    var state = try CompactState(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try state.connect()
    #expect(state.receive(.controlChange(channel: 0, number: 101, value: 127))?.isPressed == true)
    #expect(try state.setFader(1, value: 80).isEmpty)
    _ = state.receive(.controlChange(channel: 0, number: 1, value: 50))
    #expect(state.receive(.controlChange(channel: 0, number: 101, value: 0))?.isPressed == false)
    #expect(try state.reconcileReleasedFader(1) == [.controlChange(channel: 0, number: 1, value: 80)])
    #expect(try state.reconcileReleasedFader(1).isEmpty)
}

@Test func layerSelectionAlwaysTransmitsAndReconnectAvoidsMotors() throws {
    var state = try CompactState(map: FactoryStandardMap(), lightProtocol: .manual)
    #expect(state.selectLayer(.b) == .programChange(channel: 0, number: 1))
    #expect(state.selectLayer(.b) == .programChange(channel: 0, number: 1))
    _ = try state.setFader(1, value: 64)
    _ = try state.setButton(1, light: .on)
    let commands = try state.connect()
    #expect(commands.contains(.programChange(channel: 0, number: 1)))
    #expect(commands.contains(.noteOn(channel: 0, number: 0, velocity: 1)))
    #expect(!commands.contains(.controlChange(channel: 0, number: 1, value: 64)))
}

@Test func encoderRingLocalRedrawAndStyleChange() throws {
    var state = try CompactState(map: FactoryStandardMap(), lightProtocol: .observed114)
    #expect(try state.setRing(1, display: .position(7)) == [.controlChange(channel: 0, number: 26, value: 7)])
    #expect(try state.setRing(1, display: .position(7)).isEmpty)
    _ = state.receive(.controlChange(channel: 0, number: 10, value: 100))
    #expect(try state.setRing(1, display: .position(7)).count == 1)
    #expect(try state.setRingStyle(1, style: .pan) == [
        .controlChange(channel: 0, number: 10, value: 1),
        .controlChange(channel: 0, number: 26, value: 7),
    ])
}

@Test func rightButtonGroupInvalidation() throws {
    var state = try CompactState(map: FactoryStandardMap(), lightProtocol: .observed114)
    #expect(try state.setButton(34, light: .on).count == 1)
    #expect(try state.setButton(35, light: .on).count == 1)
    #expect(try state.setButton(34, light: .on).isEmpty)
    _ = state.receive(.noteOn(channel: 0, number: 49, velocity: 127)) // Button 34
    #expect(try state.setButton(35, light: .on).count == 1)
}

@Test func faderFeedbackAndInputUseDistinctPorts() throws {
    let map = try FactoryStandardMap(transmitChannel: 0, globalReceiveChannel: 2)
    var state = CompactState(map: map, lightProtocol: .observed114)
    _ = state.selectLayer(.b)
    #expect(state.receive(.controlChange(channel: 0, number: 28, value: 80))?.control == .fader(1))
    #expect(try state.setFader(1, value: 100) == [.controlChange(channel: 2, number: 1, value: 100)])
}

private func motors(_ messages: [MIDIMessage]) -> [MIDIMessage] {
    messages.filter {
        if case let .controlChange(_, n, _) = $0 {
            return (1 ... 9).contains(n)
        }; return false
    }
}

@Test func physicalLayerMismatchTracksTouchAndBlocksSoftwareAndAgentMotors() throws {
    let map = try FactoryStandardMap()
    var mock = MockXTouchCompact(map: map, lightProtocol: .manual)
    var session = CompactSession(map: map, lightProtocol: .manual)
    mock.selectPhysicalLayer(.b)
    let touch = try mock.touchFader(1, isTouched: true)
    #expect(map.decode(touch[0])?.layer == .b)
    _ = try session.receive(touch)
    #expect(session.state.isTouched(1))
    #expect(session.state.layerMismatch)
    #expect(session.state.observedLayer == .b)
    #expect(try motors(session.setFader(1, value: 100)).isEmpty)
    #expect(try motors(session.setParameter("a.Fader.1", value: 110, fromAgent: true)).isEmpty)
    let release = try session.receive(mock.touchFader(1, isTouched: false))
    #expect(!session.state.isTouched(1))
    #expect(motors(release.feedback).isEmpty)
    #expect(try motors(session.recallFaders()).isEmpty)
    #expect(session.bank(.b).faders[0] == 0)
}

@Test(arguments: [false, true]) func snappingPhysicalInputNeverEchoesToItsMotor(touched: Bool) throws {
    var config = SurfaceConfiguration.neutral
    config.parameters[0].step = 50
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.loadConfiguration(config)
    if touched {
        _ = try session.receive([.controlChange(channel: 0, number: 101, value: 127)])
    }
    for raw: UInt8 in [44, 45, 46, 49] {
        let result = try session.receive([.controlChange(channel: 0, number: 1, value: raw)])
        #expect(motors(result.feedback).isEmpty)
        #expect(session.parameters.values["a.Fader.1"] == 50)
        #expect(session.state.observedFader(1) == raw)
        #expect(!session.state.isMotorPending(1))
    }
    let release = try session.receive([.controlChange(channel: 0, number: 101, value: 0)])
    #expect(motors(release.feedback).isEmpty)
    config.parameters[0].isSwitch = true
    _ = try session.loadConfiguration(config)
    #expect(try motors(session.receive([.controlChange(channel: 0, number: 1, value: 70)]).feedback).isEmpty)
    #expect(session.parameters.values["a.Fader.1"] == 127)
}

@Test func sharedBindingsCannotBounceMotorReportsBackToTheOriginalFader() throws {
    var config = SurfaceConfiguration.neutral
    config.parameters[0].step = 50
    config.assignments.removeAll { $0.control == .fader(2) && $0.layer == .a }
    config.assignments.append(.init(control: .fader(2), layer: .a, action: .parameter("a.Fader.1")))
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.loadConfiguration(config)
    _ = try session.setParameter("a.Fader.1", value: 100)
    for raw: UInt8 in [1, 20, 45, 70, 90, 100] {
        for number: UInt8 in [1, 2] {
            #expect(try motors(session.receive([.controlChange(channel: 0, number: number, value: raw)]).feedback).isEmpty)
        }
    }
}

@Test func motorlessParameterWriteNeverQueuesOrReplaysAnOlderTarget() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.connect()
    #expect(session.motorFaders(boundTo: "a.Fader.1") == [1])
    #expect(session.motorFaders(boundTo: "b.Fader.1").isEmpty) // Inactive layer has no live motor.
    _ = try session.receive([.controlChange(channel: 0, number: 101, value: 127)])
    #expect(try motors(session.setParameter("a.Fader.1", value: 80)).isEmpty)
    #expect(session.state.isMotorPending(1))
    // A later motor-less write supersedes the queued target instead of leaving it to replay.
    #expect(try motors(session.setParameter("a.Fader.1", value: 20, fromAgent: true, drivesMotors: false)).isEmpty)
    #expect(!session.state.isMotorPending(1))
    #expect(session.bank(.a).faders[0] == 20)
    let release = try session.receive([.controlChange(channel: 0, number: 101, value: 0)])
    #expect(motors(release.feedback).isEmpty)
}

@Test func layerAssertionRequiresBothInputAndSafetyTouchesToBeReleased() throws {
    let map = try FactoryStandardMap()
    for index in 1 ... 9 {
        var state = CompactState(map: map, lightProtocol: .manual)
        try state.validateLayerAssertion()
        state.setSafetyTouch(index, touched: true)
        #expect(throws: CompactError.fadersTouched) { try state.validateLayerAssertion() }
        _ = state.receive(.controlChange(channel: 0, number: UInt8(110 + index), value: 127))
        state.setSafetyTouch(index, touched: false)
        #expect(throws: CompactError.fadersTouched) { try state.validateLayerAssertion() }
        _ = state.receive(.controlChange(channel: 0, number: UInt8(110 + index), value: 0))
        try state.validateLayerAssertion()
    }
}

@Test(arguments: [UInt8(101), UInt8(111)]) func crossLayerReleasePreservesMismatch(releaseAddress: UInt8) throws {
    var state = try CompactState(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = state.receive(.controlChange(channel: 0, number: 101, value: 127))
    #expect(try state.setFader(1, value: 80).isEmpty)
    _ = state.receive(.controlChange(channel: 0, number: 37, value: 20))
    _ = state.receive(.controlChange(channel: 0, number: releaseAddress, value: 0))
    #expect(!state.isTouched(1))
    #expect(state.layerMismatch)
    #expect(try state.reconcileReleasedFader(1).isEmpty)
    // Release edges of other controls cannot restore layer evidence either.
    _ = state.receive(.noteOff(channel: 0, number: 16, velocity: 0))
    #expect(state.layerMismatch)
    _ = state.receive(.controlChange(channel: 0, number: 10, value: 30))
    #expect(!state.layerMismatch)
    #expect(try state.reconcileReleasedFader(1).isEmpty) // Old pending target is invalidated.
}

@Test(arguments: [UInt8(101), UInt8(111)]) func sessionCrossLayerReleaseNeverReplaysMotor(releaseAddress: UInt8) throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.receive([.controlChange(channel: 0, number: 101, value: 127)])
    #expect(try motors(session.setFader(1, value: 80)).isEmpty)
    #expect(try motors(session.receive([.controlChange(channel: 0, number: 37, value: 20)]).feedback).isEmpty)
    #expect(try motors(session.receive([.controlChange(channel: 0, number: releaseAddress, value: 0)]).feedback).isEmpty)
    #expect(!session.state.isTouched(1))
    #expect(session.state.layerMismatch)
}
