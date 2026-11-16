#if os(macOS)
    import Combine
    import Foundation
    import SurfaceConnectionState
    import Testing
    @testable import XTouchCompactApp
    @testable import XTouchCompactCore

    @MainActor private func exportContextRouteProof(_ name: String, _ model: ConsoleModel, facts: [[String: String]]) throws {
        let audits = try [("route", #require(model.connectionContextAudit)), ("state", #require(model.session.state.contextAudit)), ("bindings", #require(model.session.parameters.contextAudit))]
        var rows: [[String: Any]] = []
        for (owner, audit) in audits {
            for row in audit.recordedComparisons {
                #expect(row.matches, "Independent native vs Kit leaf: \(row)")
                rows.append(["owner": owner, "operation": row.operation, "input": row.input, "native": row.native, "candidate": row.candidate, "matches": row.matches])
            }
        }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["XTOUCH_J3_SHADOW_REPORT_ROOT"] ?? repo.appendingPathComponent("build/j/j3-shadow").path)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["rows": rows, "comparisons": rows.count, "differences": rows.filter { !($0["matches"] as? Bool ?? false) }.count,
                                                    "operation_facts": facts], options: [.prettyPrinted, .sortedKeys])
            .write(to: root.appendingPathComponent(name + ".json"))
        print("J3_APP_SHADOW file=\(name) comparisons=\(rows.count)")
    }

    @Test @MainActor func neutralRouteShadowKeepsCosmeticDescriptorsAndRealStaleBatchRulesSeparate() throws {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true, eventMonotonicClock: { 12 }, contextReferences: legacyReferences(), connectionReference: LegacyConnectionReference())
        midi.connect(); model.setConsoleMode(.hardwareSend)
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127)])
        model.setParameter("a.Fader.1", value: 83)
        #expect(model.session.state.isMotorPending(1))
        let count = midi.sent.count
        let renamed = CompactMIDIEndpoint(id: 1, name: "Cosmetic description changed", provenance: .remoteVirtual)
        midi.onConnection?(.init(connectedInput: renamed, connectedOutput: renamed))
        #expect(model.session.state.isMotorPending(1))
        #expect(model.session.state.isTouched(1))
        #expect(midi.sent.count == count)
        #expect(model.connection.connectedInput?.provenance == .remoteVirtual)
        let routeAudit = try #require(model.connectionContextAudit)
        let cosmetic = try #require(routeAudit.recordedComparisons.last { $0.operation == "route.transition" })
        #expect(cosmetic.operation == "route.transition" && cosmetic.native == "changed=false|generation=0")
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 0)])
        model.setParameter("a.Fader.1", value: 33)
        var replaced = false
        midi.afterPinnedSend = {
            guard !replaced else { return }
            replaced = true
            midi.actualGeneration = 1
            midi.actualInputID = 2; midi.actualOutputID = 2
            let endpoint = CompactMIDIEndpoint(id: 2, name: "New route")
            midi.onConnection?(.init(generation: 1, connectedInput: endpoint, connectedOutput: endpoint))
        }
        model.recallMotors()
        midi.afterPinnedSend = nil
        #expect(replaced)
        #expect(model.connection.generation == 1)
        #expect(model.session.state.pendingMotorFacts.isEmpty)
        #expect(model.hardwareFeedbackNeedsSync)
        #expect(routeAudit.recordedComparisons.contains { $0.operation == "route.dispatch.admission" && $0.native == "false" })
        try exportContextRouteProof("route-cosmetic-vs-real-reentry", model, facts: [["route_generation": String(model.connection.generation), "needs_sync": String(model.hardwareFeedbackNeedsSync), "sent_bytes": String(reflecting: midi.sent.map(\.midi1Bytes))]])
    }

    @Test @MainActor func neutralContextShadowCannotCommitOverCallbackBindingOrTouchMutation() throws {
        for changesBinding in [false, true] {
            let midi = FakeMIDIService()
            let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true, eventMonotonicClock: { 12 }, contextReferences: legacyReferences(), connectionReference: LegacyConnectionReference())
            midi.connect(); model.setConsoleMode(.hardwareSend)
            midi.onMessages?([.controlChange(channel: 0, number: 25, value: 0)])
            let before = model.session.parameters.values["a.Fader.1"]
            model.parameterAuthority = { request in
                model.parameterAuthority = nil
                if changesBinding {
                    model.apply { try $0.loadConfiguration(.neutral) }
                }
                midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127)])
                return .init(accepted: true, actualValue: request.proposedValue, routeGeneration: request.routeGeneration, bindingGeneration: request.bindingGeneration)
            }
            model.setParameter("a.Fader.1", value: 91)
            #expect(model.error as? ParameterWriteAuthorizationError == .staleContext)
            #expect(model.session.parameters.values["a.Fader.1"] == before)
            #expect(model.session.state.isTouched(1))
            let sentBefore = midi.sent.count
            model.recallMotors()
            let newCommands = midi.sent.dropFirst(sentBefore)
            #expect(!newCommands.contains {
                if case .controlChange(_, 1, _) = $0 {
                    true
                } else {
                    false
                }
            })
            try exportContextRouteProof(changesBinding ? "binding-authority-reentry" : "touch-authority-reentry", model,
                                        facts: [["touch": String(model.session.state.isTouched(1)), "binding_generation": String(model.session.writeAuthorization.bindingGeneration), "new_sends": String(reflecting: Array(newCommands).map(\.midi1Bytes))]])
        }
    }

    @MainActor private func publicationPhaseFacts(_ model: ConsoleModel, phase: String) -> [String: String] {
        let fields = Array(Mirror(reflecting: model).children)
        let semantic = fields.first { $0.label == "neutralConnectionState" }?.value as? ConnectionState<EmptyConnectionIdentity>
        let full = model.referencedPublishedConnection
        #expect(semantic != nil && full != nil, "The independent candidate publication state must actually exist")
        guard let semantic, let full else { return ["error": "missing independent publication state"] }
        #expect(semantic.snapshot == model.connection.neutralRoute)
        #expect(semantic.connectionGeneration == model.connection.generation)
        #expect(full == model.connection)
        guard let audit = model.connectionContextAudit as? CompactContextAudit else { Issue.record("Actual test-only legacy audit is missing"); return ["error": "missing audit"] }
        audit.compare("route.external." + phase, input: "real synchronous Combine observer",
                      native: String(reflecting: full), candidate: String(reflecting: model.connection))
        return ["phase": phase, "native": String(reflecting: model.connection), "candidate": String(reflecting: full),
                "native_generation": String(model.connection.generation), "candidate_generation": String(semantic.connectionGeneration)]
    }

    @Test @MainActor func independentConnectionCandidatePublishesOnlyAtActualNativeStoreBoundaries() throws {
        for phase in ["permission", "connection", "cosmetic"] {
            let midi = FakeMIDIService()
            let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true, eventMonotonicClock: { 12 }, contextReferences: legacyReferences(), connectionReference: LegacyConnectionReference())
            midi.connect(); model.setConsoleMode(.hardwareSend); model.mcpMotorWritesAllowed = true
            let cosmetic = phase == "cosmetic"
            let outerEndpoint = CompactMIDIEndpoint(id: cosmetic ? 1 : 2, name: "outer", provenance: .physicalUSB)
            let innerEndpoint = CompactMIDIEndpoint(id: cosmetic ? 1 : 3, name: "inner", provenance: .remoteVirtual)
            let outer = CompactMIDIConnection(generation: cosmetic ? 0 : 1, connectedInput: outerEndpoint, connectedOutput: outerEndpoint)
            let inner = CompactMIDIConnection(generation: cosmetic ? 0 : 2, connectedInput: innerEndpoint, connectedOutput: innerEndpoint)
            var phaseFacts: [[String: String]] = []
            var injected = false
            func publish(_ snapshot: CompactMIDIConnection) {
                midi.actualInputID = snapshot.connectedInput?.id
                midi.actualOutputID = snapshot.connectedOutput?.id
                midi.actualGeneration = snapshot.generation
                midi.onConnection?(snapshot)
            }
            let capture: () -> Void = {
                guard !injected else { return }
                injected = true
                phaseFacts.append(publicationPhaseFacts(model, phase: phase + ".willSet.before"))
                publish(inner)
                phaseFacts.append(publicationPhaseFacts(model, phase: phase + ".willSet.afterNestedReceipt"))
            }
            let subscription: AnyCancellable = if phase == "permission" {
                model.$mcpMotorWritesAllowed.sink {
                    value in if !value {
                        capture()
                    }
                }
            } else {
                model.$connection.sink {
                    value in if value.connectedInput?.name == "outer" {
                        capture()
                    }
                }
            }
            withExtendedLifetime(subscription) { publish(outer) }
            phaseFacts.append(publicationPhaseFacts(model, phase: phase + ".stable.final"))
            #expect(injected && phaseFacts.count == 3)
            #expect(model.connection == inner)
            #expect(model.session.writeAuthorization.routeGeneration == inner.generation)
            #expect(midi.sent.isEmpty)
            try exportContextRouteProof("published-boundaries-" + phase, model, facts: phaseFacts)
        }
    }

    @Test @MainActor func connectionReferenceIsAValueAndDefaultModelRetainsNoReference() {
        let model = ConsoleModel(startsMIDI: false, midi: FakeMIDIService(), isolated: true)
        #expect(model.connectionContextAudit == nil && model.referencedPublishedConnection == nil)
        #expect(model.session.state.contextReference == nil && model.session.parameters.bindingReference == nil)
        let endpoint = CompactMIDIEndpoint(id: 1, name: "canonical")
        let base = CompactMIDIConnection(generation: 1, connectedInput: endpoint, connectedOutput: endpoint)
        let newEndpoint = CompactMIDIEndpoint(id: 2, name: "discarded")
        let next = CompactMIDIConnection(generation: 2, connectedInput: newEndpoint, connectedOutput: newEndpoint)
        var canonical = LegacyConnectionReference()
        canonical.didPublish(base, actual: base, semantic: base.neutralRoute, generation: 1)
        do {
            var candidate = canonical
            candidate.willPublish(next, current: base, changed: true, generation: 2)
            candidate.didPublish(next, actual: next, semantic: next.neutralRoute, generation: 2)
        }
        #expect(canonical.published == base)
        canonical.willPublish(next, current: base, changed: true, generation: 2)
        canonical.didPublish(next, actual: next, semantic: next.neutralRoute, generation: 2)
        #expect(canonical.published == next)
    }
#endif
