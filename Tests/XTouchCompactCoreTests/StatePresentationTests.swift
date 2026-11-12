import Testing
@testable import XTouchCompactCore

@Test func disconnectedSessionStillOwnsCompleteDisplayIntent() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    for i in 1 ... 16 {
        #expect(session.state.desiredRing(i) == .position(1))
        #expect(session.state.desiredRingStyle(i) == nil)
    }
    for i in 1 ... 39 {
        #expect(session.state.desiredButton(i) == .off)
    }
    // Initialization seeds desired state, not a fictional successful transmission.
    #expect(try session.setEncoder(1, value: 0).count == 1)
}

@Test func stateQueriesDistinguishDesiredObservedAndHeldControls() throws {
    var state = try CompactState(map: FactoryStandardMap(transmitChannel: 3, globalReceiveChannel: 9),
                                 lightProtocol: .manual)
    for i in 1 ... 9 {
        #expect(state.observedFader(i) == nil)
        #expect(!state.isTouched(i))
        #expect(!state.isMotorPending(i))
        _ = state.receive(.controlChange(channel: 3, number: UInt8(i), value: 31))
        _ = state.receive(.controlChange(channel: 3, number: UInt8(100 + i), value: 127))
        #expect(state.observedFader(i) == 31)
        #expect(state.isTouched(i))
        #expect(try state.setFader(i, value: 106).isEmpty)
        #expect(state.isMotorPending(i))
        _ = state.receive(.controlChange(channel: 3, number: UInt8(100 + i), value: 0))
        #expect(!state.isTouched(i))
        #expect(try state.reconcileReleasedFader(i).count == 1)
        #expect(!state.isMotorPending(i))
        #expect(state.observedFader(i) == 31) // Last report remains stale, never forged as 106.
    }
    for i in 1 ... 16 {
        #expect(state.desiredRing(i) == nil)
        #expect(state.desiredRingStyle(i) == nil)
        #expect(!state.isEncoderPushed(i))
        _ = try state.setRing(i, display: .blinkingPosition(8))
        _ = try state.setRingStyle(i, style: .fan)
        #expect(state.desiredRing(i) == .blinkingPosition(8))
        #expect(state.desiredRingStyle(i) == .fan)
        _ = state.receive(.noteOn(channel: 3, number: UInt8(i - 1), velocity: 127))
        #expect(state.isEncoderPushed(i))
        _ = state.receive(.noteOn(channel: 3, number: UInt8(i - 1), velocity: 0))
        #expect(!state.isEncoderPushed(i))
    }
    for i in 1 ... 39 {
        #expect(state.desiredButton(i) == nil)
        #expect(!state.isButtonDown(i))
        _ = try state.setButton(i, light: .blink)
        #expect(state.desiredButton(i) == .blink)
        _ = state.receive(.noteOn(channel: 3, number: UInt8(15 + i), velocity: 127))
        #expect(state.isButtonDown(i))
        _ = state.receive(.noteOff(channel: 3, number: UInt8(15 + i), velocity: 0))
        #expect(!state.isButtonDown(i))
    }
    #expect(state.observedFader(0) == nil)
    #expect(!state.isTouched(10))
    #expect(!state.isMotorPending(10))
    #expect(state.desiredButton(40) == nil)
    #expect(state.desiredRing(17) == nil)
    #expect(state.desiredRingStyle(17) == nil)
    #expect(!state.isButtonDown(40))
    #expect(!state.isEncoderPushed(17))
}

@Test func reconnectKeepsTouchSafetyWhileInvalidatingObservations() throws {
    var state = try CompactState(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = state.receive(.controlChange(channel: 0, number: 1, value: 31))
    _ = state.receive(.controlChange(channel: 0, number: 101, value: 127))
    _ = try state.setFader(1, value: 106)
    _ = state.receive(.noteOn(channel: 0, number: 0, velocity: 127))
    _ = state.receive(.noteOn(channel: 0, number: 16, velocity: 127))
    _ = try state.setRing(1, display: .allBlinking)
    _ = try state.setRingStyle(1, style: .spread)
    _ = try state.setButton(1, light: .blink)
    let commands = try state.connect()
    #expect(state.observedFader(1) == nil)
    #expect(state.isTouched(1))
    #expect(!state.isMotorPending(1))
    #expect(!state.isEncoderPushed(1))
    #expect(!state.isButtonDown(1))
    #expect(state.desiredRing(1) == .allBlinking)
    #expect(state.desiredRingStyle(1) == .spread)
    #expect(state.desiredButton(1) == .blink)
    #expect(!commands.contains {
        if case .controlChange(_, 1 ... 9, _) = $0 {
            true
        } else {
            false
        }
    })
}

@Test func layerChangeCancelsOldPendingMotorAndRetainsPhysicalTouch() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.connect()
    _ = try session.receive([.controlChange(channel: 0, number: 101, value: 127),
                             .controlChange(channel: 0, number: 1, value: 31)])
    #expect(try session.setFader(1, value: 106).isEmpty)
    #expect(session.state.isMotorPending(1))
    _ = try session.selectLayer(.b)
    #expect(session.state.isTouched(1))
    #expect(!session.state.isMotorPending(1))
    #expect(try session.receive([.controlChange(channel: 0, number: 111, value: 0)]).feedback.isEmpty)
    #expect(session.bank(.a).faders[0] == 106)
    #expect(session.bank(.b).faders[0] == 0)
    #expect(try session.recallFaders().contains(.controlChange(channel: 0, number: 1, value: 0)))
}

@Test func discardingPassiveMotorWritesPreservesPhysicalEvidence() throws {
    var state = try CompactState(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = state.receive(.controlChange(channel: 0, number: 101, value: 127))
    _ = state.receive(.controlChange(channel: 0, number: 1, value: 31))
    _ = try state.setFader(1, value: 90)
    #expect(state.isMotorPending(1))
    _ = state.receive(.controlChange(channel: 0, number: 37, value: 64))
    state.discardPendingMotorWrites()
    #expect(state.isTouched(1))
    #expect(state.layerMismatch)
    #expect(state.observedFader(1) == 31)
    #expect(!state.isMotorPending(1))
    _ = state.receive(.controlChange(channel: 0, number: 111, value: 0))
    #expect(try state.reconcileReleasedFader(1).isEmpty)
}

@Test func deliveredDiagnosticLayerAssertionInvalidatesMotorPositionFreshness() throws {
    var state = try CompactState(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = state.receive(.controlChange(channel: 0, number: 1, value: 42))
    #expect(try state.setFader(1, value: 42).isEmpty)
    state.didTransmitLayerAssertion()
    #expect(state.observedLayer == nil)
    #expect(state.observedFader(1) == 42) // Historical input, never a new observation.
    #expect(try state.setFader(1, value: 42) == [.controlChange(channel: 0, number: 1, value: 42)])
}
