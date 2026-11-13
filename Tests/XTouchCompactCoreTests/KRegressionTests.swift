import Foundation
import Testing
@testable import XTouchCompactCore

@Test func t04AbsoluteEncoderAtEndStopNeverBecomesAnUnboundedDelta() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.connect()
    for _ in 0 ..< 20 {
        _ = try session.receive([.controlChange(channel: 0, number: 10, value: 127)])
        #expect(session.bank(.a).encoders[0] == 127)
        #expect(session.parameters.values["a.Encoder.1"] == 127)
    }
}

@Test func t07PreparedMotorPlanIsRevokedByALaterTouch() throws {
    var state = try CompactState(map: FactoryStandardMap(), lightProtocol: .manual)
    let plan = try state.setFader(1, value: 80)
    #expect(plan.count == 1)
    _ = state.receive(.controlChange(channel: 0, number: 101, value: 127))
    #expect(state.filterFeedbackForDelivery(plan).isEmpty)
    #expect(state.isMotorPending(1))
}

@Test func t08ReleaseThenTouchInOneBatchUsesTheFinalSafetyState() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.receive([.controlChange(channel: 0, number: 101, value: 127)])
    #expect(try session.setFader(1, value: 80).isEmpty)
    let update = try session.receive([.controlChange(channel: 0, number: 101, value: 0),
                                      .controlChange(channel: 0, number: 101, value: 127)])
    #expect(update.feedback.isEmpty)
    #expect(session.state.isTouched(1))
    #expect(session.state.isMotorPending(1))
}

@Test func t15FailedMotorSendDoesNotRetainSentCacheOrClaimAnObservation() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    #expect(try session.setFader(1, value: 80) == [.controlChange(channel: 0, number: 1, value: 80)])
    session.invalidateTransportFeedback()
    #expect(session.state.observedFader(1) == nil)
    #expect(try session.setFader(1, value: 80) == [.controlChange(channel: 0, number: 1, value: 80)])
}

@Test func t28UnconfiguredPedalsNeverTriggerBusinessActions() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    var mock = try MockXTouchCompact(map: FactoryStandardMap(), lightProtocol: .manual)
    let before = session.parameters.values
    let expression = try session.receive(mock.moveExpression(127))
    let footswitch = try session.receive(mock.pressFootswitch(isDown: true))
    #expect(expression.actionIntents.isEmpty && footswitch.actionIntents.isEmpty)
    #expect(expression.feedback.isEmpty && footswitch.feedback.isEmpty)
    #expect(session.parameters.values == before)
}

@Test func t29SoftwareBankSelectionNeverEmitsProgramChange() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    for layer in [CompactLayer.b, .a] {
        let feedback = try session.selectHostLayer(layer)
        #expect(session.state.layer == layer)
        #expect(!feedback.contains {
            if case .programChange = $0 {
                true
            } else {
                false
            }
        })
        #expect(feedback.count == 55)
    }
}
