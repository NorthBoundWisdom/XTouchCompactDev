#if DEBUG
    import Foundation
    import SurfaceDeviceConformance
    import SurfaceDeviceContracts
    import SurfaceFeedbackPlanning
    import XTouchCompactCore

    func makeSchedulerSession(feedbackRecorder: FeedbackAuditRecorder? = nil, feedbackOwner: String = "core", feedbackSource: SurfaceDeviceContracts.DeviceSource = .simulation) throws -> CompactSession {
        if let feedbackRecorder {
            try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual,
                               feedbackSchedulerReference: TestFeedbackSchedulerReference(owner: feedbackOwner, source: feedbackSource, recorder: feedbackRecorder))
        } else {
            try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
        }
    }

    private func feedbackBytes(_ value: CompactFeedbackBytes) -> ScenarioPayload {
        .scalar(.text(value.data.base64EncodedString()))
    }

    private func feedbackScopePayload(_ scope: CompactFeedbackScope) -> ScenarioPayload {
        var bytes = CompactFeedbackBytes(); bytes.add(scope); return feedbackBytes(bytes)
    }

    private func feedbackGenerationScope(_ scope: CompactFeedbackScope, source: SurfaceDeviceContracts.DeviceSource?, endpoint: EndpointProvenance?) -> ScenarioPayload {
        var owned = CompactFeedbackBytes()
        owned.add(scope.hostLayer.rawValue); owned.add(Int(scope.transmitChannel)); owned.add(Int(scope.receiveChannel)); owned.add(scope.lightProtocol.rawValue)
        owned.add(scope.bindingGeneration); owned.add(scope.authorizationRouteGeneration)
        return .object(["native_lifecycle": feedbackBytes(owned), "source": source.map { .scalar(.text($0.rawValue)) } ?? .scalar(.null),
                        "endpoint": endpoint?.endpointID.map { .scalar(.text($0)) } ?? .scalar(.null),
                        "connection_generation": endpoint.map { .scalar(.text(String($0.connectionGeneration))) } ?? .scalar(.null)])
    }

    private func feedbackMessage(_ value: MIDIMessage) -> ScenarioPayload {
        .object(["midi1_bytes": .array(value.midi1Bytes.map { .scalar(.number(Double($0))) }), "native_case": .scalar(.text(String(reflecting: value)))])
    }

    private func feedbackPlanPayload(_ plan: CompactFeedbackPlan) -> ScenarioPayload {
        .object(["reference": feedbackBytes(plan.reference), "payload": feedbackMessage(plan.payload), "origin": feedbackBytes(plan.origin),
                 "scope": feedbackScopePayload(plan.scope), "source": .scalar(.text(plan.source.rawValue)),
                 "endpoint": .object(["id": plan.endpointEvidence.endpointID.map { .scalar(.text($0)) } ?? .scalar(.null),
                                      "device": plan.endpointEvidence.deviceID.map { .scalar(.text($0)) } ?? .scalar(.null),
                                      "generation": .scalar(.text(String(plan.endpointEvidence.connectionGeneration))),
                                      "origin": .scalar(.text(plan.endpointEvidence.transportOrigin.rawValue))]),
                 "evidence_raw": .object(["dispatch": feedbackBytes(plan.capturedEvidence.dispatch), "planned": feedbackBytes(plan.capturedEvidence.planned)]), "target": .scalar(.text(plan.targetID)),
                 "elements": .array(plan.affectedElements.sorted().map { .scalar(.text($0)) }),
                 "classification": .scalar(.text(plan.classification.rawValue)),
                 "side_effects": .array(plan.sideEffects.map(\.rawValue).sorted().map { .scalar(.text($0)) }),
                 "delivery": .scalar(.text(plan.deliveryMode == .direct ? "direct" : "coalescible"))])
    }

    private func feedbackDispatchPayload(_ plan: CompactFeedbackPlan) -> ScenarioPayload {
        .object(["origin": feedbackBytes(plan.origin), "scope": feedbackScopePayload(plan.scope),
                 "source": .scalar(.text(plan.source.rawValue)), "dispatch_evidence": feedbackBytes(plan.capturedEvidence.dispatch),
                 "endpoint": .object(["id": plan.endpointEvidence.endpointID.map { .scalar(.text($0)) } ?? .scalar(.null),
                                      "device": plan.endpointEvidence.deviceID.map { .scalar(.text($0)) } ?? .scalar(.null),
                                      "generation": .scalar(.text(String(plan.endpointEvidence.connectionGeneration))),
                                      "origin": .scalar(.text(plan.endpointEvidence.transportOrigin.rawValue))])])
    }

    private func feedbackDispatchPayload(_ facts: CompactFeedbackDispatchFacts) -> ScenarioPayload {
        .object(["origin": feedbackBytes(facts.origin), "scope": feedbackScopePayload(facts.scope),
                 "source": .scalar(.text(facts.source.rawValue)), "dispatch_evidence": feedbackBytes(facts.dispatchEvidence),
                 "endpoint": .object(["id": facts.endpointEvidence.endpointID.map { .scalar(.text($0)) } ?? .scalar(.null),
                                      "device": facts.endpointEvidence.deviceID.map { .scalar(.text($0)) } ?? .scalar(.null),
                                      "generation": .scalar(.text(String(facts.endpointEvidence.connectionGeneration))),
                                      "origin": .scalar(.text(facts.endpointEvidence.transportOrigin.rawValue))])])
    }

    /// The sole shared class is append-only diagnostics. All candidate state is below
    /// in a struct, and never obtained from native generated output or receipts.
    final class FeedbackAuditRecorder: @unchecked Sendable {
        let comparesGeneratedDisplay: Bool
        private var generatedDisplayCounts: [String: Int] = [:]

        init(comparesGeneratedDisplay: Bool = false) {
            self.comparesGeneratedDisplay = comparesGeneratedDisplay
        }

        func recordGeneratedDisplay(_ label: String) {
            lock.lock(); defer { lock.unlock() }
            generatedDisplayCounts[label, default: 0] += 1
        }

        var displayCounts: [String: Int] {
            lock.lock(); defer { lock.unlock() }
            return generatedDisplayCounts
        }

        private let lock = NSLock()
        private enum Record {
            case raw(Data)
            case scheduler(FeedbackSchedulerRecord)
        }

        private var records: [Record] = []
        private var catalog = FeedbackTraceCatalog()
        private var phases: [String: Int] = [:]
        private var timing: [String: Double] = [:]
        private var nextNode = 0
        private let encoder: JSONEncoder = {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; return encoder
        }()

        func store(_ value: ScenarioPayload, kind: String) {
            lock.lock(); defer { lock.unlock() }
            records.append(.raw(try! encoder.encode(value))); phases[kind, default: 0] += 1
        }

        @discardableResult func storeInput(_ envelope: SchedulerEnvelope, _ step: SchedulerStep, predecessor: Int?) -> Int {
            lock.lock(); defer { lock.unlock() }
            let start = ProcessInfo.processInfo.systemUptime
            let bytes = try! SchedulerTraceCodec.encodeInput(envelope)
            let encoded = ProcessInfo.processInfo.systemUptime
            let input = try! SchedulerTraceCodec.decodePayload(bytes)
            let parsed = ProcessInfo.processInfo.systemUptime
            let inputRef = try! catalog.intern(input)
            let interned = ProcessInfo.processInfo.systemUptime
            let stepRef = try! catalog.step(step, input: inputRef)
            let finished = ProcessInfo.processInfo.systemUptime
            timing["encode_input", default: 0] += encoded - start
            timing["decode_ast", default: 0] += parsed - encoded
            timing["intern_input", default: 0] += interned - parsed
            timing["encode_step", default: 0] += finished - interned
            nextNode += 1
            records.append(.scheduler(.init(node: nextNode, predecessor: predecessor, input: inputRef, step: stepRef)))
            phases["scheduler", default: 0] += 1
            return nextNode
        }

        var counts: [String: Int] {
            lock.lock(); defer { lock.unlock() }; return phases
        }

        func export(to url: URL) throws {
            lock.lock(); let rows = records; var catalog = catalog; let capturedTiming = timing; lock.unlock()
            let scheduler = rows.compactMap {
                row -> FeedbackSchedulerRecord? in if case let .scheduler(record) = row {
                    record
                } else {
                    nil
                }
            }
            // Cold replay below reads the actual persisted artifact through the strict reader.
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
            let handle = try FileHandle(forWritingTo: url)
            do {
                func write(_ data: Data) throws {
                    try handle.write(contentsOf: data); try handle.write(contentsOf: Data([10]))
                }
                let header: ScenarioPayload = .object(["kind": .scalar(.text("catalog-header")), "schema": .scalar(.text("2")),
                                                       "nodes": .scalar(.text(String(catalog.nodes.count))), "records": .scalar(.text(String(rows.count))),
                                                       "scheduler_records": .scalar(.text(String(scheduler.count))),
                                                       "lineage": .array(scheduler.map { .array([.scalar(.text(String($0.node))), $0.predecessor.map { .scalar(.text(String($0))) } ?? .scalar(.null)]) })])
                try write(encoder.encode(header))
                for index in catalog.nodes.indices {
                    try write(catalog.definition(index + 1))
                }
                for row in rows {
                    switch row {
                    case let .raw(data): try write(data)
                    case let .scheduler(record):
                        let fields: ScenarioPayload = .object(["kind": .scalar(.text("scheduler-catalog")), "node": .scalar(.text(String(record.node))),
                                                               "predecessor": record.predecessor.map { .scalar(.text(String($0))) } ?? .scalar(.null),
                                                               "input_ref": .scalar(.text(String(record.input))), "step_ref": .scalar(.text(String(record.step)))])
                        try write(encoder.encode(fields))
                    }
                }
                try handle.close()
            } catch { try? handle.close(); throw error }
            let readStart = ProcessInfo.processInfo.systemUptime
            var persisted = try FeedbackCatalogDocument.read(url)
            let replayStart = ProcessInfo.processInfo.systemUptime
            let replay = try persisted.replay()
            let replayEnd = ProcessInfo.processInfo.systemUptime
            var measured = capturedTiming
            measured["strict_read"] = replayStart - readStart
            measured["cold_replay"] = replayEnd - replayStart
            let report: [String: Any] = ["file": url.lastPathComponent, "seconds": measured,
                                         "live_counts": catalog.representationCounts, "cold_counts": persisted.catalog.representationCounts]
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            print("J4_REPRESENTATION_METRICS " + String(decoding: data, as: UTF8.self))
            print("J4_SHADOW path=\(url.lastPathComponent) rows=\(rows.count) input_only_replayed=\(replay.steps) peak_branch_states=\(replay.peakStates) catalog_nodes=\(catalog.nodes.count) phases=\(counts)")
        }
    }

    struct TestFeedbackSchedulerReference: CompactFeedbackSchedulerReference {
        private var generatedDisplay = GeneratedDisplayCacheReference()
        var comparesGeneratedDisplay: Bool {
            recorder.comparesGeneratedDisplay
        }

        mutating func compareGeneratedDisplay(_ input: CompactGeneratedDisplayInput, nativeProposal: MIDIMessage?, nativeState: CompactGeneratedDisplaySnapshot) {
            let predicted: (MIDIMessage?, CompactGeneratedDisplaySnapshot)
            do { predicted = try generatedDisplay.apply(input) }
            catch { preconditionFailure("Unable to predict a validated display input for \(owner): \(error)") }
            precondition(predicted.0 == nativeProposal && predicted.0?.midi1Bytes == nativeProposal?.midi1Bytes && predicted.1 == nativeState,
                         "Generated display shadow differs for \(owner): \(input), native \(String(reflecting: nativeProposal))/\(nativeState), Kit \(String(reflecting: predicted))")
            let outcome: String = switch input {
            case .request: nativeProposal == nil ? "suppressed" : "proposed"
            case let .invalidate(_, index): index == nil ? "clear" : "invalidate"
            }
            recorder.recordGeneratedDisplay(input.family.rawValue + "." + outcome)
        }

        private(set) var candidate = SchedulerCandidate()
        private(set) var ordinal: UInt64 = 0
        private var previousNode: Int?
        private var latestIngress: UInt64?
        private struct NativeOccurrence: Sendable {
            let message: MIDIMessage
            let provenance: CompactFeedbackBytes
            let scope: ScenarioPayload
            let causeOrdinal: UInt64
        }

        private var nativeOccurrences: [NativeOccurrence] = []
        private var dispatchScopes: [Data: CompactFeedbackScope] = [:]
        let recorder: FeedbackAuditRecorder
        let owner: String
        let source: SurfaceDeviceContracts.DeviceSource
        init(owner: String, source: SurfaceDeviceContracts.DeviceSource, recorder: FeedbackAuditRecorder) {
            self.owner = owner; self.source = source; self.recorder = recorder
        }

        private mutating func apply(_ input: SchedulerInput, context: ScenarioPayload) {
            if ordinal == 0 {
                ordinal += 1
                let envelope = SchedulerEnvelope(owner: owner, ordinal: ordinal, input: .initialize(.unlimited), context: context)
                let step = try! candidate.apply(envelope); previousNode = recorder.storeInput(envelope, step, predecessor: previousNode)
            }
            ordinal += 1
            let envelope = SchedulerEnvelope(owner: owner, ordinal: ordinal, input: input, context: context)
            let step = try! candidate.apply(envelope); previousNode = recorder.storeInput(envelope, step, predecessor: previousNode)
        }

        mutating func receive(_ intent: CompactFeedbackIntent, scope: CompactFeedbackScope, native _: CompactState) {
            let context = feedbackScopePayload(scope)
            func item(_ key: String, _ message: MIDIMessage, _ provenance: CompactPlannedProvenance?) -> SchedulerItem {
                var bytes = CompactFeedbackBytes(); bytes.add(provenance)
                return try! .init(key: key, value: .object(["message": feedbackMessage(message), "captured_provenance": feedbackBytes(bytes)]),
                                  scope: feedbackGenerationScope(scope, source: provenance?.source, endpoint: provenance?.endpoint))
            }
            switch intent {
            case let .request(key, message, provenance): apply(.requestDirect(item(key, message, provenance)), context: context)
            case let .style(key, message, projection, provenance): apply(.changeStyle(style: item(key, message, provenance), projectionKey: projection), context: context)
            case let .release(key): apply(.release(key: key), context: context)
            case let .cancel(key): apply(.cancel(key: key), context: context)
            case .clear: apply(.clear, context: context)
            case let .invalidate(keys): apply(.invalidateCache(affectedKeys: keys), context: context)
            case let .refresh(order): apply(.refreshDesired(order: order), context: context)
            }
            latestIngress = ordinal
        }

        mutating func generated(_ messages: [MIDIMessage], scope: CompactFeedbackScope, provenance: [CompactPlannedProvenance?]) {
            precondition(messages.count == provenance.count, "complete feedback occurrence provenance")
            if let cause = latestIngress {
                for (message, origin) in zip(messages, provenance) {
                    var raw = CompactFeedbackBytes(); raw.add(origin)
                    nativeOccurrences.append(.init(message: message, provenance: raw,
                                                   scope: feedbackGenerationScope(scope, source: origin?.source, endpoint: origin?.endpoint), causeOrdinal: cause))
                }
            }
            recorder.store(.object(["kind": .scalar(.text("native-generated")), "owner": .scalar(.text(owner)),
                                    "scope": feedbackScopePayload(scope), "messages": .array(messages.map(feedbackMessage)),
                                    "cause_ordinal": latestIngress.map { .scalar(.text(String($0))) } ?? .scalar(.null),
                                    "provenance": .array(provenance.map { value in var raw = CompactFeedbackBytes(); raw.add(value); return feedbackBytes(raw) }),
                                    "generation_scopes": .array(provenance.map { feedbackGenerationScope(scope, source: $0?.source, endpoint: $0?.endpoint) })]), kind: "native-generated")
        }

        private func message(_ item: SchedulerItem) -> MIDIMessage {
            guard case let .object(value) = item.value, case let .object(message) = value["message"], case let .array(raw) = message["midi1_bytes"] else { preconditionFailure("missing complete candidate payload") }
            let bytes = raw.map { value -> UInt8 in guard case let .scalar(.number(value)) = value, let byte = UInt8(exactly: value) else { preconditionFailure("non-byte candidate") }; return byte }
            if bytes.count == 3, bytes[0] & 0xF0 == 0x90 {
                return .noteOn(channel: bytes[0] & 0x0F, number: bytes[1], velocity: bytes[2])
            }
            guard let result = MIDI1UMPCodec.decode(0x2000_0000 | bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (16 - 8 * $1.offset) }) else { preconditionFailure("invalid candidate MIDI") }
            return result
        }

        mutating func dispatch(_ facts: CompactFeedbackDispatchFacts, native: CompactState) {
            // Each candidate owns its proposal. Nothing is selected from native outputs.
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            dispatchScopes[try! encoder.encode(feedbackDispatchPayload(facts))] = native.feedbackScope
            for proposal in candidate.snapshot.awaitingGate {
                let payload = message(proposal.item)
                let (target, elements, _, classification, effects) = try! CompactNeutralProjection.feedbackShape(payload, map: native.map, hostLayer: native.layer)
                let plan = try! SchedulerTracePlan(reference: .scalar(.text(String(proposal.ordinal))), payload: proposal.item.value,
                                                   origin: feedbackBytes(facts.origin), scope: .object(["generation": proposal.item.scope, "dispatch": feedbackScopePayload(facts.scope)]), source: facts.source,
                                                   endpointEvidence: facts.endpointEvidence,
                                                   capturedEvidence: SchedulerTraceCodec.queuedEvidence(for: proposal.item, nativeDispatch: feedbackDispatchPayload(facts)),
                                                   targetID: target, affectedElements: elements, classification: classification, sideEffects: effects, deliveryMode: .direct)
                let scope = facts.currentScope
                let mechanism = classification == .mechanism || classification == .management
                var rejection: String?
                if scope.hardwareMode, !scope.handoverInactive || scope.listenOnly || scope.observationMode && !facts.testAllowed {
                    rejection = "native_output_mode"
                }
                if facts.authorizedTestRequested {
                    if let diagnostic = facts.diagnostic {
                        do { try diagnostic.gate.validate(diagnostic.authorization, messages: [payload], context: diagnostic.context) }
                        catch { rejection = "native_diagnostic_command_or_scope" }
                    } else {
                        rejection = "missing_native_diagnostic_facts"
                    }
                    if !facts.testAllowed {
                        rejection = "native_diagnostic_approval"
                    }
                }
                if mechanism, scope.agentMotorPermission == false {
                    rejection = "native_agent_mechanism_permission"
                }
                if scope.hardwareMode, classification == .mechanism, !facts.hardwareMotorActionCurrent {
                    rejection = "native_explicit_motor_action"
                }
                if scope.hardwareMode, classification == .management {
                    do { try native.validateLayerAssertion() } catch { rejection = "native_global_touch" }
                    // No arbitrary candidate request can manufacture a local layer operation.
                    if !facts.managementIntent {
                        rejection = "missing_local_management_intent"
                    }
                }
                var copy = native; copy.feedbackSchedulerReference = nil
                if copy.filterFeedbackForDelivery([payload]).isEmpty {
                    rejection = "native_device_filter"
                }
                let authorization: PlanAuthorization
                if let currentAuthorization = scope.authorization {
                    let allowed = mechanism ? currentAuthorization.allowsMechanisms : currentAuthorization.allowsDisplay
                    authorization = allowed ? .granted(directions: plan.requiredDirections) : .denied(reason: "native_authorization")
                } else {
                    authorization = .denied(reason: "missing_current_authorization")
                }
                var proofFacts = facts.nativeSnapshot; proofFacts.add(scope); proofFacts.add(facts.hardwareMotorActionCurrent); proofFacts.add(facts.testAllowed); proofFacts.add(facts.authorizedTestRequested); proofFacts.add(facts.managementIntent); proofFacts.add(facts.diagnostic != nil)
                if let diagnostic = facts.diagnostic {
                    proofFacts.add(String(reflecting: diagnostic))
                }
                let proof = SchedulerTraceProof(plan: plan, nativeSnapshot: feedbackBytes(proofFacts), authorization: authorization,
                                                safety: rejection.map { .rejected(reason: $0) } ?? .passed)
                let gate = SchedulerGateRecord(proposalOrdinal: proposal.ordinal, proposedItem: proposal.item, dispatchPlan: plan, proof: proof,
                                               currentScope: .object(["generation": feedbackGenerationScope(native.feedbackScope, source: facts.source, endpoint: facts.endpointEvidence), "dispatch": feedbackScopePayload(facts.currentScope)]), currentNativeSnapshot: feedbackBytes(proofFacts))
                apply(.gate(gate), context: feedbackScopePayload(scope))
            }
        }

        mutating func receipt(_ plan: CompactFeedbackPlan, result: FeedbackAttemptResult, currentScope: CompactFeedbackScope, stateScope: CompactFeedbackScope, currentSource: SurfaceDeviceContracts.DeviceSource, currentEndpoint: EndpointProvenance) {
            // Association must include the entire queued value/scope, ordered occurrence,
            // and actual dispatch plan. Missing or different provenance stays unmatched.
            // Do not make an item from native bytes to consume a candidate target.
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            let dispatchKey = try! encoder.encode(feedbackDispatchPayload(plan))
            let originalNativeScope = dispatchScopes[dispatchKey]
            let actualGeneration = originalNativeScope.map { feedbackGenerationScope($0, source: plan.source, endpoint: plan.endpointEvidence) }
            // Unknown creation provenance is not proof, and a reference is not globally
            // unique. Use the original generated causal occurrence only if it is proven.
            let occurrences = nativeOccurrences.enumerated().filter { _, fact in
                plan.capturedEvidence.planned.data.first == 1 && fact.message == plan.payload
                    && fact.provenance == plan.capturedEvidence.planned && fact.scope == actualGeneration
            }
            let occurrence = occurrences.count == 1 ? occurrences.first : nil
            let matching = occurrence.flatMap { _, fact in
                candidate.snapshot.awaitingReceipt.first { ready in
                    guard case let .object(item) = ready.proposal.item.value else { return false }
                    return ready.proposal.causeOrdinal == fact.causeOrdinal
                        && message(ready.proposal.item) == plan.payload && ready.plan.origin == feedbackBytes(plan.origin)
                        && ready.plan.source == plan.source
                        && item["captured_provenance"] == feedbackBytes(plan.capturedEvidence.planned)
                        && ready.proposal.item.scope == actualGeneration
                        && ready.plan.capturedEvidence == SchedulerTraceCodec.queuedEvidence(for: ready.proposal.item, nativeDispatch: feedbackDispatchPayload(plan))
                }
            }
            if let ready = matching {
                recorder.store(.object(["kind": .scalar(.text("matched-native-receipt")), "plan": feedbackPlanPayload(plan),
                                        "candidate_ordinal": .scalar(.text(String(ready.proposal.ordinal))),
                                        "native_cause_ordinal": .scalar(.text(String(occurrence!.element.causeOrdinal))),
                                        "result": .scalar(.text(String(reflecting: result)))]), kind: "matched-native-receipt")
                nativeOccurrences.remove(at: occurrence!.offset)
                apply(.receipt(.init(item: ready.proposal.item, dispatchPlan: ready.plan, result: result,
                                     currentScope: .object(["generation": feedbackGenerationScope(stateScope, source: currentSource, endpoint: currentEndpoint), "dispatch": feedbackScopePayload(currentScope)]))), context: feedbackScopePayload(currentScope))
            } else {
                // Feed the actual external receipt to the shared candidate as well. Its
                // unmatched association is persistent; it cannot update an accepted cache.
                let key = switch plan.payload {
                case let .controlChange(_, number, _):
                    if (1 ... 9).contains(number) {
                        "fader.\(number)"
                    } else if (10 ... 25).contains(number) {
                        "style.\(number - 9)"
                    } else if (26 ... 41).contains(number) {
                        "ring.\(number - 25)"
                    } else {
                        "native.unclassified"
                    }
                case let .noteOn(_, number, _), let .noteOff(_, number, _): "button.\(Int(number) + 1)"
                case .programChange: "device.layer"
                default: "native.unclassified"
                }
                let generation = actualGeneration ?? .scalar(.null)
                let actualScope: ScenarioPayload = .object(["generation": generation, "dispatch": feedbackScopePayload(plan.scope)])
                let item = try! SchedulerItem(key: key, value: .object(["message": feedbackMessage(plan.payload),
                                                                        "captured_provenance": feedbackBytes(plan.capturedEvidence.planned)]), scope: generation)
                let actual = try! SchedulerTracePlan(reference: feedbackBytes(plan.reference), payload: item.value, origin: feedbackBytes(plan.origin),
                                                     scope: actualScope, source: plan.source, endpointEvidence: plan.endpointEvidence,
                                                     capturedEvidence: SchedulerTraceCodec.queuedEvidence(for: item, nativeDispatch: feedbackDispatchPayload(plan)),
                                                     targetID: plan.targetID, affectedElements: plan.affectedElements, classification: plan.classification,
                                                     sideEffects: plan.sideEffects, deliveryMode: plan.deliveryMode)
                apply(.receipt(.init(item: item, dispatchPlan: actual, result: result,
                                     currentScope: .object(["generation": feedbackGenerationScope(stateScope, source: currentSource, endpoint: currentEndpoint), "dispatch": feedbackScopePayload(currentScope)]))), context: feedbackScopePayload(currentScope))
                recorder.store(.object(["kind": .scalar(.text("unmatched-native-receipt")), "owner": .scalar(.text(owner)),
                                        "plan": feedbackPlanPayload(plan), "result": .scalar(.text(String(reflecting: result))),
                                        "current_scope": feedbackScopePayload(currentScope)]), kind: "unmatched-native-receipt")
            }
        }

        mutating func reset() {
            // A real configuration reset is input, not a native-state seed.
            generatedDisplay = GeneratedDisplayCacheReference()
            apply(.clear, context: .scalar(.text("reconfigure")))
        }
    }

#endif
