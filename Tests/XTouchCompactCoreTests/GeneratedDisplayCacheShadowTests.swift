import Testing
@testable import XTouchCompactCore
@testable import XTouchFeedbackTestSupport

private func displayShadowFixture() throws -> (CompactState, FeedbackAuditRecorder) {
    let recorder = FeedbackAuditRecorder(comparesGeneratedDisplay: true)
    var state = try CompactState(map: FactoryStandardMap(transmitChannel: 2, globalReceiveChannel: 5), lightProtocol: .manual)
    state.feedbackSchedulerReference = TestFeedbackSchedulerReference(owner: "direct-display", source: .simulation, recorder: recorder)
    return (state, recorder)
}

@Test func generatedDisplayShadowCoversStyleRedrawOrderAndInvalidRingRequests() throws {
    var (state, recorder) = try displayShadowFixture()
    #expect(try state.setRing(1, display: .position(7)).map(\.midi1Bytes) == [[0xB5, 0x1A, 7]])
    #expect(try state.setRingStyle(1, style: .fan).map(\.midi1Bytes) == [[0xB5, 0x0A, 2], [0xB5, 0x1A, 7]])
    #expect(try state.setRingStyle(1, style: .fan).isEmpty)
    #expect(try state.setRingStyle(16, style: .trim).map(\.midi1Bytes) == [[0xB5, 0x19, 4]])

    let beforeInvalid = recorder.displayCounts
    #expect(throws: CompactError.invalidDisplayPosition(0)) { try state.setRing(1, display: .position(0)) }
    #expect(throws: CompactError.invalidDisplayPosition(14)) { try state.setRing(1, display: .blinkingPosition(14)) }
    #expect(throws: CompactError.invalidIndex("button", 40)) { try state.setButton(40, light: .on) }
    #expect(throws: CompactError.invalidIndex("encoder", 17)) { try state.setRingStyle(17, style: .fan) }
    #expect(recorder.displayCounts == beforeInvalid)
    #expect(state.desiredRing(1) == .position(7) && state.generatedRingProposal(1) == .position(7))
    #expect(try state.setRing(1, display: .position(7)).isEmpty)

    _ = try state.setRing(2, display: .position(3))
    _ = try state.setButton(39, light: .on)
    _ = try state.setButton(1, light: .on)
    state.invalidateNonMotorFeedback()
    #expect(try state.restoreNonMotorFeedback().map(\.midi1Bytes) == [
        [0xB5, 0x0A, 2], [0xB5, 0x1A, 7], [0xB5, 0x19, 4],
        [0xB5, 0x1B, 3], [0x95, 0, 1], [0x95, 38, 1],
    ])
    #expect(recorder.displayCounts["style.proposed"] == 4)
    #expect(recorder.displayCounts["style.suppressed"] == 1)
    #expect(recorder.displayCounts["ring.invalidate"] == 4)
}

@Test func generatedDisplayShadowSeparatesActualInvalidationFromMetadataAndHostLayerChanges() throws {
    var (state, recorder) = try displayShadowFixture()
    _ = try state.setRing(1, display: .position(7))
    _ = try state.setRing(2, display: .position(8))
    _ = try state.setButton(1, light: .on)
    for index in 34 ... 39 {
        _ = try state.setButton(index, light: .on)
    }

    state.setResourceAuthorization(.init(routeGeneration: 14, bindingGeneration: 3))
    state.selectHostLayer(.a)
    #expect(try state.setRing(1, display: .position(7)).isEmpty)
    #expect(try state.setButton(1, light: .on).isEmpty)
    #expect(state.receive(.controlChange(channel: 2, number: 10, value: 1))?.control == .encoder(1))
    #expect(try state.setRing(1, display: .position(7)).map(\.midi1Bytes) == [[0xB5, 0x1A, 7]])
    #expect(try state.setRing(2, display: .position(8)).isEmpty)

    #expect(state.receive(.noteOn(channel: 2, number: 49, velocity: 127))?.control == .button(34))
    let redraw = try (34 ... 39).flatMap { try state.setButton($0, light: .on) }
    #expect(redraw.map(\.midi1Bytes) == (33 ... 38).map { [0x95, UInt8($0), 1] })
    #expect(try state.setButton(1, light: .on).isEmpty)
    #expect(state.receive(.noteOff(channel: 2, number: 16, velocity: 0))?.isPressed == false)
    #expect(try state.setButton(1, light: .on).map(\.midi1Bytes) == [[0x95, 0, 1]])
    #expect(recorder.displayCounts["button.invalidate"] == 7)

    var copy = try state.reconfigured(map: FactoryStandardMap(transmitChannel: 2, globalReceiveChannel: 6), lightProtocol: .observed114)
    #expect(try copy.connect(assertLayer: false).isEmpty)
    #expect(try copy.setButton(1, light: .on).map(\.midi1Bytes) == [[0x96, 0, 2]])
    #expect(try state.setButton(1, light: .on).isEmpty)
}

@Test func generatedDisplayShadowDetectsReceiptBasedEqualityInPlaceOfProposalEquality() throws {
    let map = try FactoryStandardMap()
    let input = CompactGeneratedDisplayInput.request(index: 1, value: .ring(.position(7)), scope: .init(), map: map, lightProtocol: .manual)
    var proposalCache = GeneratedDisplayCacheReference()
    var receiptCache = GeneratedDisplayCacheReference(policy: .suppressAfterAcceptedReceipt)
    #expect(try proposalCache.apply(input).0 == receiptCache.apply(input).0)
    #expect(try proposalCache.apply(input).0 == nil)
    #expect(try receiptCache.apply(input).0 != nil)
}
