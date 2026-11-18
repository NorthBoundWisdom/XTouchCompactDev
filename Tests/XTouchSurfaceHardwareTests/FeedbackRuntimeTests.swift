import SurfaceControlContracts
import Testing
import XTouchCompactCore
@testable import XTouchSurfaceHardware

func hardwareFeedbackFixture(configuration: CompactHardwareConfiguration) throws -> (CompactHardwareSurface, ControlFeedback) {
    var surface = try CompactHardwareSurface(instanceID: "feedback.test", epoch: "initial", configuration: configuration,
                                             hardwareWriterID: "local", remoteWriterID: "remote")
    try surface.transition(epoch: "connected", connected: true, at: 1)
    _ = try surface.receive(.controlChange(channel: 0, number: 10, value: 0), at: 2)
    let request = ControlFeedback(expected: surface.controls.expected, expectedSequence: surface.controls.discovery().latest_sequence,
                                  controlID: "a.encoder.1", kind: "value", value: .number(5))
    return (surface, request)
}

func hardwareFeedbackTestAdmission(_ message: HardwareDisplayMessage, origin: HardwareEndpointOrigin) throws -> HardwareDisplayAdmission {
    let expected = ControlExpected(instanceID: "feedback.test", epoch: "connected", mappingRevision: "test", profileID: "test", profileVersion: "1.4")
    let request = ControlFeedback(expected: expected, controlID: "a.encoder.1", kind: "value", value: .number(5))
    return try .init(message, index: 0, request: request, writer: "remote", fallbackWriter: "remote", origin: origin, at: 3)
}

@Test func ordinarySenderRefreshesAndRejectsStalePinBeforeValidatingIllegalWord() throws {
    let configuration = try CompactHardwareConfiguration(receiveChannel: 0, lightProtocol: .manual)
    let origin = HardwareEndpointOrigin(inputID: 11, outputID: 12, connectionGeneration: 7, transportOrigin: "unknown")
    var refreshes = 0
    var words: [UInt32] = []
    let sender = CoreHardwareMIDI(configuration: configuration, audit: .init(access: .enabled),
                                  source: 1, destination: 2, origin: origin,
                                  discover: { refreshes += 1; return (1, 2) }, sendWord: { _, word in words.append(word) })
    let illegal = HardwareDisplayMessage.ringDisplay(encoder: 1, value: 29)
    var stale = origin; stale.connectionGeneration -= 1
    let staleIllegal = try hardwareFeedbackTestAdmission(illegal, origin: stale)
    #expect(staleIllegal.plan.payload == illegal)
    #expect(staleIllegal.plan.requiredDirections == [.display])
    #expect(throws: ControlContractError("invalid_transition")) { try sender.send(staleIllegal) }
    #expect(refreshes == 1 && words.isEmpty)
    let currentIllegal = try hardwareFeedbackTestAdmission(illegal, origin: origin)
    #expect(throws: ControlContractError("invalid_value")) { try sender.send(currentIllegal) }
    #expect(refreshes == 2 && words.isEmpty)
    try sender.send(hardwareFeedbackTestAdmission(.ringDisplay(encoder: 1, value: 5), origin: origin))
    #expect(refreshes == 3 && words == [0x20B0_1A05])
}

@Test func ordinaryFeedbackTransactionDoesNotCommitAfterSecondTransportCallFails() throws {
    let configuration = try CompactHardwareConfiguration(receiveChannel: 0, lightProtocol: .manual)
    let origin = HardwareEndpointOrigin(inputID: 11, outputID: 12, connectionGeneration: 7, transportOrigin: "unknown")
    var (surface, request) = try hardwareFeedbackFixture(configuration: configuration)
    let before = try surface.controls.snapshot(at: 3)
    var budget = SurfaceWriteBudgets(aggregateLimit: 1)
    var words: [UInt32] = []
    let sender = CoreHardwareMIDI(configuration: configuration, audit: .init(access: .enabled),
                                  source: 1, destination: 2, origin: origin, discover: { (1, 2) }, sendWord: { _, word in
                                      words.append(word)
                                      if words.count == 2 {
                                          throw ControlContractError("transport_error")
                                      }
                                  })
    #expect(throws: ControlContractError("transport_error")) {
        try performHardwareFeedback(request, allowed: true, writer: "remote", at: 3, origin: origin,
                                    surface: &surface, budget: &budget, midi: sender)
    }
    #expect(words.count == 2)
    let after = try surface.controls.snapshot(at: 3)
    #expect(after.feedback == before.feedback)
    #expect(after.latest_sequence == before.latest_sequence)
    let couldWriteAgain = budget.consume(.feedback, at: 3, writerID: "remote")
    #expect(!couldWriteAgain)
}
