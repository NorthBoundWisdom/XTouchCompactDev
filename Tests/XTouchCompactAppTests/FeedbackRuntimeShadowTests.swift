@testable import XTouchFeedbackTestSupport
#if os(macOS)
    import Foundation
    import SurfaceDeviceContracts
    import SurfaceFeedbackPlanning
    import Testing
    @testable import XTouchCompactApp
    @testable import XTouchCompactCore

    @Test @MainActor func feedbackCapturedRoutePreservesUnicodeCosmeticAndMissingDescriptorFacts() {
        let nfc = CompactMIDIEndpoint(id: 1, name: "\u{e9}", provenance: .physicalUSB)
        let nfd = CompactMIDIEndpoint(id: 1, name: "e\u{301}", provenance: .physicalUSB)
        let a = CompactMIDIConnection(generation: 3, inputs: [nfc], outputs: [nfc], connectedInput: nfc, connectedOutput: nfc)
        let b = CompactMIDIConnection(generation: 3, inputs: [nfd], outputs: [nfd], connectedInput: nfd, connectedOutput: nfd)
        #expect(a.neutralRoute == b.neutralRoute)
        let p = ConsoleFeedbackProjection.evidence(a, output: .init(endpoint: nfc, generation: 3), planned: nil, knownLayer: nil, at: -0.0, authorizedTest: nil)
        let q = ConsoleFeedbackProjection.evidence(b, output: .init(endpoint: nfd, generation: 3), planned: nil, knownLayer: nil, at: -0.0, authorizedTest: nil)
        #expect(p != q)
        var empty = a; empty.inputs = []
        #expect(ConsoleFeedbackProjection.evidence(empty, output: .init(endpoint: nfc, generation: 3), planned: nil, knownLayer: nil, at: -0.0, authorizedTest: nil) != p)
        var origin = a; origin.connectedOutput?.provenance = .remoteVirtual
        #expect(origin.neutralRoute == a.neutralRoute)
        #expect(ConsoleFeedbackProjection.evidence(origin, output: .init(endpoint: origin.connectedOutput, generation: 3), planned: nil, knownLayer: nil, at: -0.0, authorizedTest: nil) != p)
    }

    @Test @MainActor func consoleFeedbackPlanKeepsNativeDirectionsOnAnyChannel() throws {
        let map = try FactoryStandardMap(globalReceiveChannel: 0)
        var scope = CompactFeedbackScope()
        scope.authorization = .init()
        let cases: [(MIDIMessage, ConsoleFeedbackProjection.OutputKind, Set<EffectDirection>)] = [
            (.controlChange(channel: 15, number: 1, value: 12), .fader, [.mechanism]),
            (.controlChange(channel: 7, number: 9, value: 12), .fader, [.mechanism]),
            (.controlChange(channel: 15, number: 10, value: 1), .display, [.display]),
            (.programChange(channel: 15, number: 1), .layer, [.management, .mechanism]),
        ]
        for (message, expectedKind, required) in cases {
            let kind = ConsoleFeedbackProjection.OutputKind(message)
            let plan = try ConsoleFeedbackProjection.plan(message, index: 0, actor: .mock, scope: scope, bindingGeneration: 0, route: .init(),
                                                          output: .simulation, planned: nil, knownLayer: nil, map: map, at: 1, authorizedTest: nil)
            #expect(kind == expectedKind)
            #expect(kind.stageDirection == (required == [.display] ? .display : .mechanism))
            #expect(plan.requiredDirections == required)
            let facts = CompactFeedbackBytes()
            let proof = CompactFeedbackPlanning.nativeOutputProof(plan: plan, message: message, nativeDirections: kind.requiredDirections,
                                                                  permittedDirections: required, nativeSnapshot: facts, safety: .passed)
            #expect(FeedbackPreflight.evaluate(plan: plan, proof: proof, currentScope: scope, currentNativeSnapshot: facts) == .permitted)
        }
    }

    @Test @MainActor func feedbackShadowRecordsPinRejectionAsAttemptAndKeepsOldScopeOnAcceptedReentry() throws {
        for reject in [false, true] {
            let wire = FakeMIDIService()
            var operation = 0
            let model = ConsoleModel(startsMIDI: false, midi: wire, isolated: true, eventMonotonicClock: { 13 }, plannedIntentIDFactory: {
                operation += 1
                return "fixture.pin.\(reject).operation.\(operation)"
            })
            let audit = FeedbackAuditRecorder()
            model.installFeedbackShadow(audit, scheduler: TestFeedbackSchedulerReference(owner: "pin", source: .hardware, recorder: audit))
            wire.connect(); model.setConsoleMode(.hardwareSend)
            wire.onMessages?([.controlChange(channel: 0, number: 25, value: 0)])
            if reject {
                wire.actualGeneration = 8
            } else {
                var once = false
                wire.afterPinnedSend = {
                    guard !once else { return }; once = true
                    wire.actualGeneration = 8
                    let endpoint = CompactMIDIEndpoint(id: 1, name: "new route")
                    wire.onConnection?(.init(generation: 8, connectedInput: endpoint, connectedOutput: endpoint))
                }
            }
            let attempts = wire.sendAttempts
            model.apply { session in session.invalidateNonMotorFeedback(); return try session.setDisplayButton(1, light: .on) }
            #expect(wire.sendAttempts > attempts)
            #expect((audit.counts["receipt"] ?? 0) > 0)
            #expect((audit.counts["preflight"] ?? 0) > 0)
            if reject {
                #expect(model.error != nil)
            } else {
                #expect(model.connection.generation == 8)
            }
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["XTOUCH_J4_SHADOW_REPORT_ROOT"] ?? "build/j/j4-shadow")
            try audit.export(to: root.appendingPathComponent(reject ? "pin-rejected.jsonl" : "pin-accepted-old-scope.jsonl"))
        }
    }

    @MainActor private func feedbackOwnerRevision(_ model: ConsoleModel) -> UInt64 {
        Mirror(reflecting: model).children.first { $0.label == "canonicalSessionRevision" }!.value as! UInt64
    }

    @Test @MainActor func feedbackMetadataInstallationAndEmptyDispatchDoNotMutateCanonicalOwner() {
        for installed in [false, true] {
            let wire = FakeMIDIService()
            let model = ConsoleModel(startsMIDI: false, midi: wire, isolated: true)
            let beforeInstall = feedbackOwnerRevision(model)
            if installed {
                let recorder = FeedbackAuditRecorder()
                model.installFeedbackShadow(recorder, scheduler: TestFeedbackSchedulerReference(owner: "metadata", source: .simulation, recorder: recorder))
            } else {
                model.installFeedbackShadow(nil, scheduler: nil)
            }
            #expect(feedbackOwnerRevision(model) == beforeInstall)
            let beforeQuery = feedbackOwnerRevision(model)
            _ = model.session.parameters.values; _ = model.session.state.observedLayer
            #expect(feedbackOwnerRevision(model) == beforeQuery)
            model.apply { _ in [] }
            // One actual canonical apply commit. Empty dispatch is diagnostics only.
            #expect(feedbackOwnerRevision(model) == beforeQuery + 1)
            let beforeActualOutput = feedbackOwnerRevision(model)
            model.apply { session in session.invalidateNonMotorFeedback(); return try session.setDisplayButton(1, light: .on) }
            // One real apply commit plus one original canonical device filter.
            // Shadow dispatch and actual receipt add no owner mutation.
            #expect(feedbackOwnerRevision(model) == beforeActualOutput + 2)
        }
    }

    @Test @MainActor func feedbackOnlyMetadataInsideTrustedAuthorityDoesNotRejectAValidProposal() {
        let wire = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: wire, isolated: true)
        let recorder = FeedbackAuditRecorder()
        var called = false
        model.parameterAuthority = { request in
            called = true
            let before = feedbackOwnerRevision(model)
            model.installFeedbackShadow(recorder, scheduler: TestFeedbackSchedulerReference(owner: "authority-metadata", source: .simulation, recorder: recorder))
            #expect(feedbackOwnerRevision(model) == before)
            return .init(accepted: true, actualValue: request.proposedValue, routeGeneration: request.routeGeneration, bindingGeneration: request.bindingGeneration)
        }
        model.setParameter("a.Fader.1", value: 57)
        #expect(called)
        #expect(model.session.parameters.values["a.Fader.1"] == 57)
        #expect(model.error == nil)
    }

    @Test @MainActor func feedbackBackingKeepsActualCommitsAndBindingRevocationAtOneNativeRevision() throws {
        let model = ConsoleModel(startsMIDI: false, midi: FakeMIDIService(), isolated: true)
        let recorder = FeedbackAuditRecorder()
        model.installFeedbackShadow(recorder, scheduler: TestFeedbackSchedulerReference(owner: "real-owner", source: .simulation, recorder: recorder))
        let beforeWrite = feedbackOwnerRevision(model)
        model.apply { session in _ = try session.setParameter("a.Fader.1", value: 57); return [] }
        #expect(feedbackOwnerRevision(model) == beforeWrite + 1)
        #expect(model.session.parameters.values["a.Fader.1"] == 57)
        let beforeConfiguration = feedbackOwnerRevision(model)
        try model.configureWriteAuthorization(model.session.writeAuthorization)
        #expect(feedbackOwnerRevision(model) == beforeConfiguration + 1)
        let binding = model.session.writeAuthorization.bindingGeneration
        let beforeBinding = feedbackOwnerRevision(model)
        model.apply { session in _ = try session.loadConfiguration(.neutral); return [] }
        #expect(model.session.writeAuthorization.bindingGeneration != binding)
        #expect(feedbackOwnerRevision(model) == beforeBinding + 1)
        #expect(!model.session.writeAuthorization.allowsValues)
        #expect(!model.session.writeAuthorization.allowsDisplay)
        #expect(!model.session.writeAuthorization.allowsMechanisms)
        let value = model.session.parameters.values["a.Fader.1"]
        model.setParameter("a.Fader.1", value: 81)
        #expect(model.session.parameters.values["a.Fader.1"] == value)
        #expect(model.error != nil)
    }
#endif
