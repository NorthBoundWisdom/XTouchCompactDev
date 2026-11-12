import Testing
@testable import XTouchCompactCore

/// Behavior that the public simulation adapter must preserve when it reuses the
/// existing host engine. These tests do not grant physical hardware qualification.
@Test func simulatedFeedbackDoesNotSynthesizeControlInputs() throws {
    let map = try FactoryStandardMap()
    var mock = MockXTouchCompact(map: map, lightProtocol: .manual)
    var session = CompactSession(map: map, lightProtocol: .manual)
    mock.receive(try session.connect())
    mock.receive(try session.setEncoder(1, value: 127))
    mock.receive(try session.setFader(1, value: 91))
    #expect(mock.faders[0] == 91)
    #expect(mock.rings[0] == .position(13))
    // Neither feedback receiver returns MIDI TX; physical observations remain nil.
    #expect(session.state.observedFader(1) == nil)
    #expect(session.bank(.a).encoders[0] == 127)
}

@Test func simulatedInactiveLayerInputCannotEditActiveBankOrInvokeActions() throws {
    let map = try FactoryStandardMap()
    var mock = MockXTouchCompact(map: map, lightProtocol: .manual)
    var session = CompactSession(map: map, lightProtocol: .manual)
    _ = try session.connect()
    mock.selectPhysicalLayer(.b)
    let encoder = try session.receive(mock.turnEncoder(1, value: 92))
    let button = try session.receive(mock.pressButton(1, isDown: true))
    #expect(encoder.inputs.first?.layer == .b)
    #expect(encoder.feedback.isEmpty)
    #expect(button.actionIntents.isEmpty)
    #expect(session.bank(.a).encoders[0] == 0)
    #expect(session.bank(.b).encoders[0] == 0)
    #expect(session.state.layer == .a)
}

@Test func simulatedTouchAndReconnectKeepMotorSafety() throws {
    let map = try FactoryStandardMap()
    var mock = MockXTouchCompact(map: map, lightProtocol: .manual)
    var session = CompactSession(map: map, lightProtocol: .manual)
    _ = try session.connect()
    _ = try session.receive(mock.touchFader(1, isTouched: true))
    #expect(try session.setFader(1, value: 100).isEmpty)
    session.invalidateTransportFeedback()
    let reconnect = try session.connect()
    #expect(!reconnect.contains { if case .controlChange(_, 1 ... 9, _) = $0 { true } else { false } })
    #expect(mock.faders[0] == 0)
    #expect(session.state.isTouched(1))
}
