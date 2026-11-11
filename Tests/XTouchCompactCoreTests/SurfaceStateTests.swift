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
