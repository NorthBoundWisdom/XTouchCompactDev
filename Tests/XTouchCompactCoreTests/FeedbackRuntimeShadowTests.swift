import Foundation
import SurfaceDeviceContracts
import SurfaceFeedbackPlanning
import Testing
@testable import XTouchCompactCore
@testable import XTouchFeedbackTestSupport

private func feedbackPlan(scope: CompactFeedbackScope = .init(), evidence: CompactFeedbackBytes = .init()) throws -> CompactFeedbackPlan {
    var reference = CompactFeedbackBytes(); reference.add(0)
    var origin = CompactFeedbackBytes(); origin.add("test.local")
    return try CompactFeedbackPlanning.plan(.programChange(channel: 0, number: 0), map: FactoryStandardMap(), scope: scope,
                                            reference: reference, origin: origin, source: .simulation,
                                            endpoint: .init(endpointID: "test.virtual", deviceID: nil, connectionGeneration: 0, transportOrigin: .localVirtual), evidence: evidence)
}

@Test func feedbackCapturedEvidencePreservesUTF8PresenceAndDoubleBits() throws {
    let nfc = "\u{e9}", nfd = "e\u{301}"
    #expect(nfc == nfd)
    var a = CompactFeedbackBytes(); a.add(nfc)
    var b = CompactFeedbackBytes(); b.add(nfd)
    #expect(a != b)
    let p = try feedbackPlan(evidence: a), q = try feedbackPlan(evidence: b)
    let proof = CompactFeedbackProof(plan: p, nativeSnapshot: a, authorization: .granted(directions: p.requiredDirections), safety: .passed)
    #expect(FeedbackPreflight.evaluate(plan: q, proof: proof, currentScope: q.scope, currentNativeSnapshot: a) == .rejected(.planMismatch))
    var nilValue = CompactFeedbackBytes(); nilValue.add(nil as String?)
    var empty = CompactFeedbackBytes(); empty.add("")
    #expect(nilValue != empty)
    var positive = CompactFeedbackBytes(); positive.add(0.0)
    var negative = CompactFeedbackBytes(); negative.add(-0.0)
    #expect(positive != negative)
    var nan1 = CompactFeedbackBytes(); nan1.add(Double(bitPattern: 0x7FF8_0000_0000_0001))
    var nan2 = CompactFeedbackBytes(); nan2.add(Double(bitPattern: 0x7FF8_0000_0000_0002))
    #expect(nan1 != nan2)
}

@Test func feedbackFullUnionCannotBeBorrowedFromMechanismStage() throws {
    let plan = try feedbackPlan(); let facts = CompactFeedbackBytes()
    #expect(plan.requiredDirections == [.management, .mechanism])
    #expect(FeedbackAuthorizationCheck.evaluate(requirements: [.mechanism], authorization: .granted(directions: [.mechanism])) == .sufficient)
    let proof = CompactFeedbackProof(plan: plan, nativeSnapshot: facts, authorization: .granted(directions: [.mechanism]), safety: .passed)
    #expect(FeedbackPreflight.evaluate(plan: plan, proof: proof, currentScope: plan.scope, currentNativeSnapshot: facts) == .rejected(.wrongDirections(missing: [.management], surplus: [])))
    let full = CompactFeedbackProof(plan: plan, nativeSnapshot: facts, authorization: .granted(directions: plan.requiredDirections), safety: .passed)
    #expect(FeedbackPreflight.evaluate(plan: plan, proof: full, currentScope: plan.scope, currentNativeSnapshot: facts) == .permitted)
    var hardware = plan.scope; hardware.hardwareMode = true
    #expect(FeedbackPreflight.evaluate(plan: plan, proof: full, currentScope: hardware, currentNativeSnapshot: facts) == .rejected(.staleScope))
    var newFacts = facts; newFacts.add("new touch")
    #expect(FeedbackPreflight.evaluate(plan: plan, proof: full, currentScope: plan.scope, currentNativeSnapshot: newFacts) == .rejected(.staleNativeProof))
}

@Test func productionFeedbackProofRejectsDirectionsOutsideTheNativeGrant() throws {
    let message = MIDIMessage.noteOn(channel: 0, number: 0, velocity: 127)
    let facts = CompactFeedbackBytes()
    let scope = CompactFeedbackScope()
    let display = try CompactFeedbackPlanning.plan(message, map: FactoryStandardMap(), scope: scope,
                                                   reference: facts, origin: facts, source: .simulation,
                                                   endpoint: .init(endpointID: "test.virtual", deviceID: nil, connectionGeneration: 0, transportOrigin: .localVirtual), evidence: facts)
    let enlarged = try CompactFeedbackPlan(reference: display.reference, payload: display.payload, origin: display.origin,
                                           scope: display.scope, source: display.source, endpointEvidence: display.endpointEvidence,
                                           capturedEvidence: display.capturedEvidence, targetID: display.targetID, affectedElements: display.affectedElements,
                                           classification: display.classification, sideEffects: [.mechanism], deliveryMode: display.deliveryMode)
    // Mock can generate all three kinds of output. This wire message itself is display-only.
    let isolatedMockDirections: Set<EffectDirection> = [.display, .mechanism, .management]
    let normal = CompactFeedbackPlanning.nativeOutputProof(plan: display, message: message, receiveChannel: 0,
                                                           permittedDirections: isolatedMockDirections, nativeSnapshot: facts, safety: .passed)
    let expanded = CompactFeedbackPlanning.nativeOutputProof(plan: enlarged, message: message, receiveChannel: 0,
                                                             permittedDirections: isolatedMockDirections, nativeSnapshot: facts, safety: .passed)
    #expect(FeedbackPreflight.evaluate(plan: display, proof: normal, currentScope: scope, currentNativeSnapshot: facts) == .permitted)
    #expect(expanded.authorization == .granted(directions: [.display]))
    #expect(FeedbackPreflight.evaluate(plan: enlarged, proof: expanded, currentScope: scope, currentNativeSnapshot: facts) == .rejected(.wrongDirections(missing: [.mechanism], surplus: [])))
    let otherChannel = CompactFeedbackPlanning.nativeOutputProof(plan: display, message: message, receiveChannel: 1,
                                                                 permittedDirections: isolatedMockDirections, nativeSnapshot: facts, safety: .passed)
    #expect(FeedbackPreflight.evaluate(plan: display, proof: otherChannel, currentScope: scope, currentNativeSnapshot: facts) == .rejected(.authorizationDenied(reason: "native_output_authorization")))
    let alteredPayload = CompactFeedbackPlanning.nativeOutputProof(plan: display, message: .controlChange(channel: 0, number: 1, value: 127), receiveChannel: 0,
                                                                   permittedDirections: isolatedMockDirections, nativeSnapshot: facts, safety: .passed)
    #expect(FeedbackPreflight.evaluate(plan: display, proof: alteredPayload, currentScope: scope, currentNativeSnapshot: facts) == .rejected(.authorizationDenied(reason: "native_output_payload_mismatch")))
}

@Test func feedbackReceiptDistinguishesAdmissionAttemptFromPhysicalUnknown() throws {
    let plan = try feedbackPlan()
    for (result, attempted, accepted) in [(FeedbackAttemptResult.accepted, true, true), (.rejected(reason: "pin"), true, false), (.notAttempted(reason: "empty"), false, false)] {
        let receipt = FeedbackReceiptFact(plan: plan, result: result)
        #expect(receipt.hasTransportAttempt == attempted)
        #expect(receipt.successfulSend == accepted)
        #expect(FeedbackReceiptEligibility.acceptedInCurrentScope(receipt, currentScope: plan.scope) == accepted)
    }
    #expect(!FeedbackReceiptSummary([]).allAccepted)
    let accepted = FeedbackReceiptFact(plan: plan, result: .accepted)
    var newScope = plan.scope; newScope.transportGeneration += 1
    #expect(accepted.successfulSend)
    #expect(!FeedbackReceiptEligibility.acceptedInCurrentScope(accepted, currentScope: newScope))
}

@Test func feedbackSchedulerReferencesAreIndependentAcrossCopyCandidateAndDiscard() throws {
    var original = try CompactState(map: FactoryStandardMap(), lightProtocol: .manual)
    #expect(original.feedbackSchedulerReference == nil)
    let recorder = FeedbackAuditRecorder()
    original.feedbackSchedulerReference = TestFeedbackSchedulerReference(owner: "copy", source: .simulation, recorder: recorder)
    _ = try original.setButton(1, light: .on)
    let originalReference = try #require(original.feedbackSchedulerReference as? TestFeedbackSchedulerReference)
    var candidate = original
    _ = try candidate.setButton(2, light: .blink)
    _ = try candidate.setFader(1, value: 91)
    let candidateReference = try #require(candidate.feedbackSchedulerReference as? TestFeedbackSchedulerReference)
    #expect(candidateReference.ordinal > originalReference.ordinal)
    #expect(originalReference.candidate.snapshot.desired["button.2"] == nil)
    #expect(candidateReference.candidate.snapshot.desired["button.2"] != nil)
    #expect(original.desiredButton(2) == nil)
    // Discard the candidate and mutate the canonical value. Its own candidate had
    // not consumed operations from the discarded copy or the shared diagnostic sink.
    _ = try original.setButton(3, light: .off)
    let after = try #require(original.feedbackSchedulerReference as? TestFeedbackSchedulerReference)
    #expect(after.ordinal == originalReference.ordinal + 1)
    #expect(after.candidate.snapshot.desired["fader.1"] == nil)
    #expect(after.candidate.snapshot.desired["button.2"] == nil)
    #expect(after.candidate.snapshot.desired["button.3"] != nil)
    #expect(candidateReference.candidate.snapshot.desired["button.3"] == nil)
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["XTOUCH_J4_SHADOW_REPORT_ROOT"] ?? "build/j/j4-shadow")
    try recorder.export(to: root.appendingPathComponent("value-copy-discard.jsonl"))
}

@Test func feedbackStyleRequestIsBeforeDedupAndDoesNotDoubleFeedDerivedRedraw() throws {
    var state = try CompactState(map: FactoryStandardMap(), lightProtocol: .manual)
    let recorder = FeedbackAuditRecorder()
    state.feedbackSchedulerReference = TestFeedbackSchedulerReference(owner: "style", source: .simulation, recorder: recorder)
    _ = try state.setRing(1, display: .position(7))
    let before = try #require(state.feedbackSchedulerReference as? TestFeedbackSchedulerReference)
    let messages = try state.setRingStyle(1, style: .pan)
    let after = try #require(state.feedbackSchedulerReference as? TestFeedbackSchedulerReference)
    #expect(after.ordinal == before.ordinal + 1)
    #expect(messages == [.controlChange(channel: 0, number: 10, value: 1), .controlChange(channel: 0, number: 26, value: 7)])
    #expect(after.candidate.snapshot.awaitingGate.count == before.candidate.snapshot.awaitingGate.count + 2)
    // This second native request is generation-cache deduplicated. The shared
    // accepted-only candidate still receives it and truthfully proposes a difference.
    let second = try state.setRingStyle(1, style: .pan)
    let repeated = try #require(state.feedbackSchedulerReference as? TestFeedbackSchedulerReference)
    #expect(second.isEmpty)
    #expect(repeated.ordinal == after.ordinal + 1)
    #expect(repeated.candidate.snapshot.awaitingGate.count == after.candidate.snapshot.awaitingGate.count + 2)
}

@Test func feedbackProofBindsWholePlanRatherThanOpaqueReferenceOrPayloadAlone() throws {
    let original = try feedbackPlan()
    let facts = CompactFeedbackBytes()
    let proof = CompactFeedbackProof(plan: original, nativeSnapshot: facts, authorization: .granted(directions: original.requiredDirections), safety: .passed)
    var differentOrigin = original.origin; differentOrigin.add("another actual actor")
    var differentScope = original.scope; differentScope.hardwareMode = true
    var differentReference = original.reference; differentReference.add("second operation")
    var differentEvidence = original.capturedEvidence.dispatch; differentEvidence.add("qualification/presence changed")
    let variations = try [
        CompactFeedbackPlan(reference: original.reference, payload: .programChange(channel: 0, number: 1), origin: original.origin, scope: original.scope, source: original.source, endpointEvidence: original.endpointEvidence, capturedEvidence: original.capturedEvidence, targetID: original.targetID, affectedElements: original.affectedElements, classification: original.classification, sideEffects: original.sideEffects, deliveryMode: original.deliveryMode),
        CompactFeedbackPlan(reference: original.reference, payload: original.payload, origin: differentOrigin, scope: original.scope, source: original.source, endpointEvidence: original.endpointEvidence, capturedEvidence: original.capturedEvidence, targetID: original.targetID, affectedElements: original.affectedElements, classification: original.classification, sideEffects: original.sideEffects, deliveryMode: original.deliveryMode),
        CompactFeedbackPlan(reference: original.reference, payload: original.payload, origin: original.origin, scope: differentScope, source: .hardware, endpointEvidence: original.endpointEvidence, capturedEvidence: original.capturedEvidence, targetID: original.targetID, affectedElements: original.affectedElements, classification: original.classification, sideEffects: original.sideEffects, deliveryMode: original.deliveryMode),
        CompactFeedbackPlan(reference: differentReference, payload: original.payload, origin: original.origin, scope: original.scope, source: original.source, endpointEvidence: original.endpointEvidence, capturedEvidence: original.capturedEvidence, targetID: original.targetID, affectedElements: original.affectedElements, classification: original.classification, sideEffects: original.sideEffects, deliveryMode: original.deliveryMode),
        CompactFeedbackPlan(reference: original.reference, payload: original.payload, origin: original.origin, scope: original.scope, source: original.source, endpointEvidence: original.endpointEvidence, capturedEvidence: .init(dispatch: differentEvidence, planned: original.capturedEvidence.planned), targetID: original.targetID, affectedElements: original.affectedElements, classification: original.classification, sideEffects: original.sideEffects, deliveryMode: original.deliveryMode),
    ]
    for plan in variations {
        #expect(FeedbackPreflight.evaluate(plan: plan, proof: proof, currentScope: plan.scope, currentNativeSnapshot: facts) == .rejected(.planMismatch))
    }
    let surplus = CompactFeedbackProof(plan: original, nativeSnapshot: facts, authorization: .granted(directions: [.display, .management, .mechanism]), safety: .passed)
    #expect(FeedbackPreflight.evaluate(plan: original, proof: surplus, currentScope: original.scope, currentNativeSnapshot: facts) == .rejected(.wrongDirections(missing: [], surplus: [.display])))
    let withheld = CompactFeedbackProof(plan: original, nativeSnapshot: facts, authorization: .granted(directions: original.requiredDirections), safety: .rejected(reason: "native_touch_layer_gate"))
    #expect(FeedbackPreflight.evaluate(plan: original, proof: withheld, currentScope: original.scope, currentNativeSnapshot: facts) == .rejected(.nativeRejected(reason: "native_touch_layer_gate")))
}

private func feedbackDispatchFacts(_ state: CompactState, message: MIDIMessage, planned: CompactPlannedProvenance? = nil) throws -> (CompactFeedbackPlan, CompactFeedbackDispatchFacts) {
    var scope = state.feedbackScope; scope.authorization = .init()
    var reference = CompactFeedbackBytes(); reference.add(0)
    var origin = CompactFeedbackBytes(); origin.add("test-sender")
    let endpoint = try EndpointProvenance(endpointID: "test-owned", deviceID: nil, connectionGeneration: 0, transportOrigin: .localVirtual)
    let plan = try CompactFeedbackPlanning.plan(message, map: state.map, scope: scope, reference: reference, origin: origin, source: .simulation, endpoint: endpoint, evidence: .init(), planned: planned)
    return (plan, .init(scope: scope, source: .simulation, origin: origin, endpointEvidence: endpoint, dispatchEvidence: plan.capturedEvidence.dispatch,
                        currentScope: scope, nativeSnapshot: state.feedbackNativeSnapshot, hardwareMotorActionCurrent: false,
                        testAllowed: false, authorizedTestRequested: false, managementIntent: true))
}

@Test func feedbackSchedulerAcceptedOnlyCacheDiffersFromNativeGenerationCacheAfterFailure() throws {
    for accepted in [false, true] {
        let recorder = FeedbackAuditRecorder()
        var state = try CompactState(map: FactoryStandardMap(), lightProtocol: .manual)
        state.feedbackSchedulerReference = TestFeedbackSchedulerReference(owner: "cache", source: .simulation, recorder: recorder)
        let planned = try feedbackTestProvenance("cache.operation")
        let output = try state.setFader(1, value: 83, provenance: planned)
        let (plan, facts) = try feedbackDispatchFacts(state, message: #require(output.first), planned: planned)
        var reference = try #require(state.feedbackSchedulerReference as? TestFeedbackSchedulerReference)
        var copy = state; copy.feedbackSchedulerReference = nil
        reference.dispatch(facts, native: copy)
        #expect(reference.candidate.snapshot.awaitingReceipt.count == 1)
        reference.receipt(plan, result: accepted ? .accepted : .rejected(reason: "actual-test-sender-failure"), currentScope: plan.scope, stateScope: state.feedbackScope, currentSource: plan.source, currentEndpoint: plan.endpointEvidence)
        #expect((reference.candidate.snapshot.acceptedCache["fader.1"] != nil) == accepted)
        state.feedbackSchedulerReference = reference
        let before = reference.candidate.snapshot.awaitingGate.count
        #expect(try state.setFader(1, value: 83, provenance: planned).isEmpty)
        let repeated = try #require(state.feedbackSchedulerReference as? TestFeedbackSchedulerReference)
        #expect(repeated.candidate.snapshot.awaitingGate.count == before + (accepted ? 0 : 1))
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["XTOUCH_J4_SHADOW_REPORT_ROOT"] ?? "build/j/j4-shadow")
        try recorder.export(to: root.appendingPathComponent(accepted ? "accepted-cache.jsonl" : "failed-generation-cache-difference.jsonl"))
    }
}

@Test func feedbackSchedulerEmptyNativeOutputStillEvaluatesHoldAndReleaseUsesItsOwnTarget() throws {
    let recorder = FeedbackAuditRecorder()
    var state = try CompactState(map: FactoryStandardMap(), lightProtocol: .manual)
    state.feedbackSchedulerReference = TestFeedbackSchedulerReference(owner: "release", source: .simulation, recorder: recorder)
    _ = state.receive(.controlChange(channel: 0, number: 101, value: 127))
    let planned = try feedbackTestProvenance("held.operation")
    #expect(try state.setFader(1, value: 83, provenance: planned).isEmpty)
    let (plan, facts) = try feedbackDispatchFacts(state, message: .controlChange(channel: 0, number: 1, value: 83), planned: planned)
    var reference = try #require(state.feedbackSchedulerReference as? TestFeedbackSchedulerReference)
    var copy = state; copy.feedbackSchedulerReference = nil
    reference.dispatch(facts, native: copy)
    #expect(reference.candidate.snapshot.withheld.count == 1)
    #expect(reference.candidate.snapshot.awaitingReceipt.isEmpty)
    state.feedbackSchedulerReference = reference
    _ = state.receive(.controlChange(channel: 0, number: 101, value: 0))
    let actual = try state.reconcileReleasedFader(1)
    #expect(actual == [plan.payload])
    let released = try #require(state.feedbackSchedulerReference as? TestFeedbackSchedulerReference)
    #expect(released.candidate.snapshot.withheld.isEmpty)
    #expect(released.candidate.snapshot.awaitingGate.count == 1)
    #expect(released.candidate.snapshot.awaitingGate.first?.cause == .release)
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["XTOUCH_J4_SHADOW_REPORT_ROOT"] ?? "build/j/j4-shadow")
    try recorder.export(to: root.appendingPathComponent("empty-native-held-release.jsonl"))
}

private func feedbackTestProvenance(_ id: String) throws -> CompactPlannedProvenance {
    try .init(id: id, source: .simulation,
              endpoint: .init(endpointID: "test-owned", deviceID: nil, connectionGeneration: 0, transportOrigin: .localVirtual),
              context: .init(id: "test-owned", generation: "0", mappingRevision: nil), origin: .interface, at: 1.0)
}

@Test func feedbackReceiptNeverConsumesUnknownOrAmbiguousNativeCausalOccurrences() throws {
    for known in [false, true] {
        let recorder = FeedbackAuditRecorder()
        var state = try CompactState(map: FactoryStandardMap(), lightProtocol: .manual)
        state.feedbackSchedulerReference = TestFeedbackSchedulerReference(owner: "unproven", source: .simulation, recorder: recorder)
        let planned = known ? try feedbackTestProvenance("reused-reference") : nil
        _ = try state.setFader(1, value: 83, provenance: planned)
        if known {
            state.invalidateMotorCommandHistory()
            _ = try state.setFader(1, value: 83, provenance: planned)
        }
        let (plan, facts) = try feedbackDispatchFacts(state, message: .controlChange(channel: 0, number: 1, value: 83), planned: planned)
        var reference = try #require(state.feedbackSchedulerReference as? TestFeedbackSchedulerReference)
        var copy = state; copy.feedbackSchedulerReference = nil
        reference.dispatch(facts, native: copy)
        reference.receipt(plan, result: .accepted, currentScope: plan.scope, stateScope: state.feedbackScope, currentSource: .simulation, currentEndpoint: plan.endpointEvidence)
        #expect(reference.candidate.snapshot.acceptedCache.isEmpty)
        #expect(reference.candidate.snapshot.persistentAlignmentDifferences.count == 1)
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["XTOUCH_J4_SHADOW_REPORT_ROOT"] ?? "build/j/j4-shadow")
        try recorder.export(to: root.appendingPathComponent(known ? "ambiguous-reused-reference.jsonl" : "unknown-receipt.jsonl"))
    }
}

@Test func feedbackCandidateRechecksTheExactOriginalDiagnosticCommandOnAValueGate() throws {
    let recorder = FeedbackAuditRecorder()
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual,
                                     feedbackSchedulerReference: TestFeedbackSchedulerReference(owner: "diagnostic", source: .hardware, recorder: recorder))
    let endpoint = try EndpointProvenance(endpointID: "2", deviceID: nil, connectionGeneration: 5, transportOrigin: .localVirtual)
    let planned = try CompactPlannedProvenance(id: "diagnostic-operation", source: .hardware, endpoint: endpoint,
                                               context: .init(id: "diagnostic", generation: "5", mappingRevision: nil), origin: .interface, at: 1.0)
    _ = try session.withPlannedProvenance(planned) { value in
        try value.setDisplayButton(1, light: .on) + value.setDisplayButton(2, light: .on)
    }
    var gate = NonMotorTestGate()
    let context = NonMotorTransportContext(inputID: 1, outputID: 2, recording: true, generation: 5)
    try gate.arm(.init(standardModeConfirmed: true, stage1Reviewed: true, stage1Evidence: "test", firmware: "test", receiveChannel: 0, receiveChannelEvidence: "test"), context: context, id: "diagnostic-approval")
    let authorization = try gate.authorize(.button(1, .on, .manual), context: context)
    var scope = session.state.feedbackScope; scope.authorization = .init(allowsMechanisms: false)
    scope.hardwareMode = true; scope.observationMode = true; scope.inputID = 1; scope.outputID = 2; scope.transportGeneration = 5; scope.connected = true
    var actor = CompactFeedbackBytes(); actor.add("local-diagnostic")
    let facts = CompactFeedbackDispatchFacts(scope: scope, source: .hardware, origin: actor, endpointEvidence: endpoint,
                                             dispatchEvidence: .init(), currentScope: scope, nativeSnapshot: session.state.feedbackNativeSnapshot,
                                             hardwareMotorActionCurrent: false, testAllowed: true, authorizedTestRequested: true, managementIntent: false,
                                             diagnostic: .init(gate: gate, authorization: authorization, context: context))
    var reference = try #require(session.state.feedbackSchedulerReference as? TestFeedbackSchedulerReference)
    var native = session.state; native.feedbackSchedulerReference = nil
    reference.dispatch(facts, native: native)
    #expect(reference.candidate.snapshot.awaitingReceipt.count == 1)
    #expect(reference.candidate.snapshot.awaitingReceipt.first?.proposal.item.key == "button.1")
    #expect(reference.candidate.snapshot.withheld.contains { $0.key == "button.2" })
    // The approved gate is unchanged; the candidate only validated its value copy.
    #expect(gate.approval?.id == "diagnostic-approval")
    #expect(try gate.authorize(.button(1, .on, .manual), context: context) == authorization)
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["XTOUCH_J4_SHADOW_REPORT_ROOT"] ?? "build/j/j4-shadow")
    try recorder.export(to: root.appendingPathComponent("candidate-specific-diagnostic-gate.jsonl"))
}
