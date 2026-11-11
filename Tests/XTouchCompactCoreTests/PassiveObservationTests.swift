import Testing
@testable import XTouchCompactCore

@Test func passiveObservationKeepsPhysicalSafetyWithoutExecutingAssignments() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    let parameters = session.parameters.values
    let bankA = session.bank(.a)
    let bankB = session.bank(.b)
    session.observeInputs([
        .controlChange(channel: 0, number: 111, value: 127),
        .controlChange(channel: 0, number: 28, value: 76),
        .controlChange(channel: 0, number: 37, value: 88),
        .noteOn(channel: 0, number: 71, velocity: 127),
    ])
    #expect(session.parameters.values == parameters)
    #expect(session.bank(.a) == bankA)
    #expect(session.bank(.b) == bankB)
    #expect(session.state.isTouched(1))
    #expect(session.state.observedFader(1) == 76)
    #expect(session.state.layerMismatch)
    #expect(session.state.isButtonDown(1))
    session.observeInputs([.controlChange(channel: 0, number: 101, value: 0),
                           .noteOff(channel: 0, number: 71, velocity: 0)])
    #expect(!session.state.isTouched(1))
    #expect(!session.state.isButtonDown(1))
}
