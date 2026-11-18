import Foundation
import SurfaceDeviceConformance
import SurfaceDeviceContracts
import SurfaceFeedbackPlanning
import Testing
@testable import XTouchFeedbackTestSupport

private struct CatalogFixture {
    var catalog = FeedbackTraceCatalog()
    var candidate = SchedulerCandidate()
    var records: [FeedbackSchedulerRecord] = []
    var ordinal: UInt64 = 0
    let encoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value }()
    mutating func apply(_ input: SchedulerInput) throws -> SchedulerStep {
        ordinal += 1
        let envelope = SchedulerEnvelope(owner: "catalog", ordinal: ordinal, input: input, context: .object(["explicit_null": .scalar(.null)]))
        let step = try candidate.apply(envelope)
        let inputBytes = try SchedulerTraceCodec.encodeInput(envelope)
        let inputTree = try JSONDecoder().decode(ScenarioPayload.self, from: inputBytes)
        let outputTree = FeedbackStepPayload.make(step, input: inputTree)
        let oldOutput = try SchedulerTraceCodec.encodeStep(step)
        #expect(try encoder.encode(outputTree) == oldOutput)
        let inRef = try catalog.intern(inputTree), outRef = try catalog.intern(outputTree)
        #expect(try catalog.canonicalData(inRef) == inputBytes)
        #expect(try catalog.canonicalData(outRef) == oldOutput)
        records.append(.init(node: records.count + 1, predecessor: records.isEmpty ? nil : records.count, input: inRef, step: outRef))
        return step
    }
}

private func catalogItem(_ value: Double) throws -> SchedulerItem {
    try .init(key: "element", value: .object(["value": .scalar(.number(value)), "raw_text": .scalar(.text("e\u{301}")), "null": .scalar(.null)]), scope: .scalar(.text("scope")))
}

private func catalogPlan(_ proposal: SchedulerProposal) throws -> SchedulerTracePlan {
    try .init(reference: .scalar(.text(String(proposal.ordinal))), payload: proposal.item.value, origin: .scalar(.text("actor")), scope: proposal.item.scope,
              source: .simulation, endpointEvidence: .init(endpointID: nil, deviceID: nil, connectionGeneration: 0, transportOrigin: .unknown),
              capturedEvidence: SchedulerTraceCodec.queuedEvidence(for: proposal.item, nativeDispatch: .scalar(.null)), targetID: proposal.item.key,
              affectedElements: ["element"], classification: .display, sideEffects: [], deliveryMode: .direct)
}

@Test func feedbackCatalogWholeStepsMatchOriginalCodecAcrossAllGateResultsAndReceipts() throws {
    var fixture = CatalogFixture()
    _ = try fixture.apply(.initialize(.bucket(perSecond: 50, burst: 3, errorCooldown: 0.5)))
    _ = try fixture.apply(.enqueue(catalogItem(1), ingress: .externalRequest))
    let drained = try fixture.apply(.drain(at: 1))
    let first = try #require(drained.proposals.first)
    let firstPlan = try catalogPlan(first)
    _ = try fixture.apply(.gate(.init(proposalOrdinal: first.ordinal, proposedItem: first.item, dispatchPlan: firstPlan,
                                      proof: .init(plan: firstPlan, nativeSnapshot: .scalar(.null), authorization: .granted(directions: [.display]), safety: .passed),
                                      currentScope: first.item.scope, currentNativeSnapshot: .scalar(.null))))
    _ = try fixture.apply(.receipt(.init(item: first.item, dispatchPlan: firstPlan, result: .accepted, currentScope: first.item.scope)))
    for index in 0 ..< 6 {
        let step = try fixture.apply(.requestDirect(catalogItem(Double(index + 2))))
        let proposal = try #require(step.proposals.first); let plan = try catalogPlan(proposal)
        var proofPlan = plan; var scope = plan.scope
        var proofNative = ScenarioPayload.scalar(.null), currentNative = proofNative
        var authorization = PlanAuthorization.granted(directions: [.display]); var safety = NativeSafetyResult.passed
        switch index {
        case 0: proofPlan = firstPlan
        case 1: scope = .scalar(.text("other"))
        case 2: proofNative = .scalar(.text("old")); currentNative = .scalar(.text("fresh"))
        case 3: authorization = .denied(reason: "e\u{301}")
        case 4: authorization = .granted(directions: [.mechanism])
        default: safety = .rejected(reason: "device gate")
        }
        _ = try fixture.apply(.gate(.init(proposalOrdinal: proposal.ordinal, proposedItem: proposal.item, dispatchPlan: plan,
                                          proof: .init(plan: proofPlan, nativeSnapshot: proofNative, authorization: authorization, safety: safety),
                                          currentScope: scope, currentNativeSnapshot: currentNative)))
    }
    _ = try fixture.apply(.changeStyle(style: catalogItem(9), projectionKey: "projection"))
    _ = try fixture.apply(.refreshDesired(order: ["element", "projection"]))
    _ = try fixture.apply(.invalidateCache(affectedKeys: ["element"]))
    _ = try fixture.apply(.failure(at: 1.2))
    _ = try fixture.apply(.cancel(key: "element"))
    _ = try fixture.apply(.clear)
    let result = try FeedbackBranchReplay.validate(fixture.records, catalog: &fixture.catalog)
    #expect(result.steps == fixture.records.count)
    #expect(result.peakStates <= 1)
}

@Test func feedbackCatalogKeysRetainUTF8DoubleBitsNullPresenceAndArrayMultiplicity() throws {
    var catalog = FeedbackTraceCatalog()
    let nfc = try catalog.intern(.scalar(.text("\u{e9}"))), nfd = try catalog.intern(.scalar(.text("e\u{301}")))
    #expect(nfc != nfd)
    #expect(try catalog.intern(.scalar(.number(0.0))) != catalog.intern(.scalar(.number(-0.0))))
    #expect(try catalog.intern(.object(["field": .scalar(.null)])) != catalog.intern(.object([:])))
    #expect(try catalog.intern(.array([.scalar(.text("a")), .scalar(.text("b"))])) != catalog.intern(.array([.scalar(.text("b")), .scalar(.text("a"))])))
    #expect(try catalog.intern(.array([.scalar(.text("a")), .scalar(.text("a"))])) != catalog.intern(.array([.scalar(.text("a"))])))
    var decoded = FeedbackTraceCatalog()
    for index in catalog.nodes.indices {
        try decoded.readDefinition(catalog.definition(index + 1))
    }
    #expect(decoded.nodes.count == catalog.nodes.count)
    for index in catalog.nodes.indices {
        #expect(try decoded.canonicalData(index + 1) == catalog.canonicalData(index + 1))
    }
    #expect(throws: FeedbackTraceCatalog.Failure.self) { try decoded.expand(decoded.nodes.count + 1) }
    #expect(throws: FeedbackTraceCatalog.Failure.self) { try decoded.readDefinition(Data(#"{"kind":"catalog-node","id":"999999","type":"array","children":["999999"]}"#.utf8)) }
}

@Test func feedbackCatalogBranchReplayRejectsMissingParentWrongBranchDroppedFieldAndWrongReference() throws {
    var catalog = FeedbackTraceCatalog(); var candidate = SchedulerCandidate()
    var records: [FeedbackSchedulerRecord] = []
    func make(_ candidate: inout SchedulerCandidate, input: SchedulerInput, ordinal: UInt64, node: Int, parent: Int?) throws -> FeedbackSchedulerRecord {
        let envelope = SchedulerEnvelope(owner: "branch", ordinal: ordinal, input: input)
        let step = try candidate.apply(envelope)
        let tree = try JSONDecoder().decode(ScenarioPayload.self, from: SchedulerTraceCodec.encodeInput(envelope))
        return try .init(node: node, predecessor: parent, input: catalog.intern(tree), step: catalog.intern(FeedbackStepPayload.make(step, input: tree)))
    }
    try records.append(make(&candidate, input: .initialize(.unlimited), ordinal: 1, node: 1, parent: nil))
    var branch = candidate
    try records.append(make(&candidate, input: .requestDirect(catalogItem(1)), ordinal: 2, node: 2, parent: 1))
    try records.append(make(&branch, input: .requestDirect(catalogItem(2)), ordinal: 2, node: 3, parent: 1))
    try records.append(make(&candidate, input: .requestDirect(catalogItem(3)), ordinal: 3, node: 4, parent: 2))
    #expect(try FeedbackBranchReplay.validate(records, catalog: &catalog).steps == 4)
    let last = records[3]
    var bad = records; bad[3] = .init(node: last.node, predecessor: 99, input: last.input, step: last.step)
    #expect(throws: FeedbackBranchReplay.Failure.self) { try FeedbackBranchReplay.validate(bad, catalog: &catalog) }
    bad[3] = .init(node: last.node, predecessor: 3, input: last.input, step: last.step)
    #expect(throws: FeedbackBranchReplay.Failure.self) { try FeedbackBranchReplay.validate(bad, catalog: &catalog) }
    guard case var .object(output) = try catalog.expand(last.step) else { Issue.record("object required"); return }
    output.removeValue(forKey: "state")
    bad[3] = try .init(node: last.node, predecessor: last.predecessor, input: last.input, step: catalog.intern(.object(output)))
    #expect(throws: FeedbackBranchReplay.Failure.self) { try FeedbackBranchReplay.validate(bad, catalog: &catalog) }
    bad[3] = .init(node: last.node, predecessor: last.predecessor, input: last.input, step: last.input)
    #expect(throws: FeedbackBranchReplay.Failure.self) { try FeedbackBranchReplay.validate(bad, catalog: &catalog) }
}

@Test func feedbackCatalogComponentMemoMissesEveryChangedFieldAndSameBucketBranchValue() throws {
    var catalog = FeedbackTraceCatalog()
    let a = try SchedulerItem(key: "same-key", value: .scalar(.text("\u{e9}")), scope: .scalar(.number(0.0)))
    let b = try SchedulerItem(key: "same-key", value: .scalar(.text("e\u{301}")), scope: .scalar(.number(0.0)))
    let c = try SchedulerItem(key: "same-key", value: a.value, scope: .scalar(.number(-0.0)))
    let item = try catalog.item(a)
    #expect(try item == (catalog.item(a)))
    #expect(try item != (catalog.item(b)))
    #expect(try item != (catalog.item(c)))
    func plan(_ changed: Int) throws -> SchedulerTracePlan {
        try .init(reference: .scalar(.text(changed == 0 ? "other-reference" : "same-reference")),
                  payload: .scalar(.number(changed == 1 ? -0.0 : 0.0)), origin: .scalar(.text(changed == 2 ? "e\u{301}" : "\u{e9}")),
                  scope: changed == 3 ? .object([:]) : .object(["explicit": .scalar(.null)]), source: changed == 4 ? .hardware : .simulation,
                  endpointEvidence: .init(endpointID: changed == 5 ? "e\u{301}" : "\u{e9}", deviceID: changed == 6 ? "device" : nil,
                                          connectionGeneration: changed == 7 ? 2 : 1, transportOrigin: changed == 8 ? .remoteVirtual : .localVirtual),
                  capturedEvidence: changed == 9 ? .array([.scalar(.number(2)), .scalar(.number(1))]) : .array([.scalar(.number(1)), .scalar(.number(2))]),
                  targetID: changed == 10 ? "e\u{301}" : "\u{e9}", affectedElements: [changed == 11 ? "e\u{301}" : "\u{e9}"],
                  classification: changed == 12 ? .management : .display, sideEffects: changed == 13 ? [.mechanism] : [],
                  deliveryMode: changed == 14 ? .coalescible : .direct)
    }
    let original = try plan(-1), reference = try catalog.plan(original)
    #expect(try reference == (catalog.plan(original)))
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    for field in 0 ... 14 {
        _ = try catalog.plan(original)
        let misses = catalog.planMemoMisses
        let changed = try plan(field), newReference = try catalog.plan(changed)
        #expect(catalog.planMemoMisses == misses + 1)
        let hits = catalog.planMemoHits
        #expect(try catalog.plan(changed) == newReference)
        #expect(catalog.planMemoHits == hits + 1)
        #expect(reference != newReference, "Field \(field) must miss even inside the same reference bucket")
        #expect(try catalog.canonicalData(newReference) == encoder.encode(SchedulerTraceCodec.planPayload(changed)))
    }
}

@Test func feedbackCatalogReaderRejectsOldAcceptedNoncanonicalOrOpenDefinitions() throws {
    for raw in [
        #"{"kind":"catalog-node","id":"1","type":"null","extra":true}"#,
        #"{"kind":"catalog-node","id":"01","type":"null"}"#,
        #"{"kind":"catalog-node","id":"1","type":"number","bits":"00"}"#,
        #"{"kind":"catalog-node","id":"1","type":"null","type":"null"}"#,
        #"{"kind":"catalog-node","id":"1","type":"null","ignored":{"x":1,"x":2}}"#,
    ] {
        var catalog = FeedbackTraceCatalog()
        #expect(throws: (any Error).self) { try catalog.readDefinition(Data(raw.utf8)) }
    }
}

@Test func feedbackCatalogRejectsDuplicateZeroOrReorderedSourceNodeIdentityEvenForValidOutputs() throws {
    var catalog = FeedbackTraceCatalog(); var candidate = SchedulerCandidate()
    let input = SchedulerEnvelope(owner: "identity", ordinal: 1, input: .initialize(.unlimited))
    let step = try candidate.apply(input)
    let tree = try JSONDecoder().decode(ScenarioPayload.self, from: SchedulerTraceCodec.encodeInput(input))
    let inRef = try catalog.intern(tree), outRef = try catalog.intern(FeedbackStepPayload.make(step, input: tree))
    for node in [0, 2] {
        #expect(throws: (any Error).self) {
            try FeedbackBranchReplay.validate([.init(node: node, predecessor: nil, input: inRef, step: outRef)], catalog: &catalog)
        }
    }
    let nextInput = SchedulerEnvelope(owner: "identity", ordinal: 2, input: .clear)
    let next = try candidate.apply(nextInput)
    let nextTree = try JSONDecoder().decode(ScenarioPayload.self, from: SchedulerTraceCodec.encodeInput(nextInput))
    let nextRef = try catalog.intern(nextTree), nextStep = try catalog.intern(FeedbackStepPayload.make(next, input: nextTree))
    #expect(throws: (any Error).self) {
        try FeedbackBranchReplay.validate([.init(node: 1, predecessor: nil, input: inRef, step: outRef), .init(node: 1, predecessor: 1, input: nextRef, step: nextStep)], catalog: &catalog)
    }
}

@Test func feedbackCatalogMustCheckTheActualStepInputInsteadOfEmbeddingExpectedInput() throws {
    var catalog = FeedbackTraceCatalog(); var candidate = SchedulerCandidate()
    let input = SchedulerEnvelope(owner: "actual-owner", ordinal: 1, input: .initialize(.unlimited), context: .object(["kept": .scalar(.null)]))
    let actual = try candidate.apply(input)
    for wrong in [SchedulerEnvelope(owner: "other-owner", ordinal: 1, input: input.input, context: input.context),
                  SchedulerEnvelope(owner: input.owner, ordinal: 2, input: input.input, context: input.context),
                  SchedulerEnvelope(owner: input.owner, ordinal: 1, input: input.input)]
    {
        let bytes = try SchedulerTraceCodec.encodeInput(wrong)
        let reference = try catalog.intern(JSONDecoder().decode(ScenarioPayload.self, from: bytes))
        #expect(throws: (any Error).self) { try catalog.step(actual, input: reference) }
    }
}

private func feedbackV2Bytes(_ fixture: CatalogFixture) throws -> [Data] {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let records = fixture.records
    var lines = try [encoder.encode(ScenarioPayload.object(["kind": .scalar(.text("catalog-header")), "schema": .scalar(.text("2")),
                                                            "nodes": .scalar(.text(String(fixture.catalog.nodes.count))), "records": .scalar(.text(String(records.count))),
                                                            "scheduler_records": .scalar(.text(String(records.count))),
                                                            "lineage": .array(records.map { .array([.scalar(.text(String($0.node))), $0.predecessor.map { .scalar(.text(String($0))) } ?? .scalar(.null)]) })]))]
    for index in fixture.catalog.nodes.indices {
        try lines.append(fixture.catalog.definition(index + 1))
    }
    for record in records {
        try lines.append(encoder.encode(ScenarioPayload.object(["kind": .scalar(.text("scheduler-catalog")), "node": .scalar(.text(String(record.node))),
                                                                "predecessor": record.predecessor.map { .scalar(.text(String($0))) } ?? .scalar(.null),
                                                                "input_ref": .scalar(.text(String(record.input))), "step_ref": .scalar(.text(String(record.step)))])))
    }
    return lines
}

private func feedbackReadLines(_ lines: [Data]) throws -> FeedbackCatalogDocument {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let path = directory.appendingPathComponent("trace.jsonl")
    var bytes = Data(); for line in lines {
        bytes.append(line); bytes.append(10)
    }; try bytes.write(to: path)
    return try FeedbackCatalogDocument.read(path)
}

@Test func feedbackCatalogPersistedReaderRequiresClosedCanonicalHeaderDefinitionsAndRecords() throws {
    var fixture = CatalogFixture(); _ = try fixture.apply(.initialize(.unlimited)); _ = try fixture.apply(.clear)
    let good = try feedbackV2Bytes(fixture); var document = try feedbackReadLines(good)
    #expect(try document.replay().steps == 2)
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let header = try FeedbackStrictJSON.object(good[0])
    for key in header.keys {
        var missing = header; missing.removeValue(forKey: key); var bad = good; bad[0] = try encoder.encode(ScenarioPayload.object(missing))
        #expect(throws: (any Error).self) { try feedbackReadLines(bad) }
    }
    for (key, replacement) in [("schema", ScenarioPayload.scalar(.number(2))), ("schema", .scalar(.text("02"))), ("nodes", .scalar(.text("0001"))), ("records", .scalar(.text("3"))), ("scheduler_records", .scalar(.text("1"))), ("unknown", .scalar(.null))] {
        var header = header; header[key] = replacement; var bad = good; bad[0] = try encoder.encode(ScenarioPayload.object(header))
        #expect(throws: (any Error).self) { try feedbackReadLines(bad) }
    }
    var bad = good; bad.removeLast()
    #expect(throws: (any Error).self) { try feedbackReadLines(bad) }
    bad = good; try bad.append(#require(good.last))
    #expect(throws: (any Error).self) { try feedbackReadLines(bad) }
    let record = try FeedbackStrictJSON.object(#require(good.last))
    for key in record.keys {
        var missing = record; missing.removeValue(forKey: key); bad = good; bad[bad.count - 1] = try encoder.encode(ScenarioPayload.object(missing))
        #expect(throws: (any Error).self) { try feedbackReadLines(bad) }
    }
    for (key, replacement) in [("node", ScenarioPayload.scalar(.text("02"))), ("node", .scalar(.number(2))), ("predecessor", .scalar(.text("2"))), ("input_ref", .scalar(.text("0001"))), ("step_ref", .scalar(.text("999999"))), ("extra", .scalar(.null))] {
        var value = record; value[key] = replacement; bad = good; bad[bad.count - 1] = try encoder.encode(ScenarioPayload.object(value))
        #expect(throws: (any Error).self) { try feedbackReadLines(bad) }
    }
    bad = good; bad[0] = Data((String(decoding: good[0].dropLast(), as: UTF8.self) + ",\"schema\":\"2\"}").utf8)
    #expect(throws: (any Error).self) { try feedbackReadLines(bad) }
    for raw in [#"{"kind":"catalog-node","id":"1","type":"array","children":["1"]}"#,
                #"{"kind":"catalog-node","id":"1","type":"number","bits":"+0"}"#,
                #"{"kind":"catalog-node","id":"1","type":"text","utf8":"YQ==\n"}"#,
                #"{"kind":"catalog-node","id":"1","type":"bool"}"#]
    {
        var catalog = FeedbackTraceCatalog()
        #expect(throws: (any Error).self) { try catalog.readDefinition(Data(raw.utf8)) }
    }
}

@Test func feedbackCatalogDeclaredLineageRejectsEvenEquivalentWrongParentAndNestedOmissions() throws {
    var fixture = CatalogFixture(); _ = try fixture.apply(.initialize(.unlimited))
    // Two valid identical states/outputs can still have distinct source identities.
    var candidate = SchedulerCandidate(); let envelope = SchedulerEnvelope(owner: "same", ordinal: 1, input: .initialize(.unlimited))
    let step = try candidate.apply(envelope), bytes = try SchedulerTraceCodec.encodeInput(envelope)
    let input = try fixture.catalog.intern(JSONDecoder().decode(ScenarioPayload.self, from: bytes)), output = try fixture.catalog.step(step, input: input)
    let records = [FeedbackSchedulerRecord(node: 1, predecessor: nil, input: input, step: output), .init(node: 2, predecessor: nil, input: input, step: output)]
    #expect(try FeedbackBranchReplay.validate(records, catalog: &fixture.catalog).steps == 2)
    #expect(throws: (any Error).self) { try FeedbackBranchReplay.validate(records, catalog: &fixture.catalog, declared: [.init(node: 1, parent: nil), .init(node: 2, parent: 1)]) }
    #expect(throws: (any Error).self) { try FeedbackStepPayload.requireLayout(["key", "value"], ["key", "value", "scope"]) }
    var active = CatalogFixture(); _ = try active.apply(.initialize(.unlimited))
    let prepared = try active.apply(.requestDirect(catalogItem(1))), own = try #require(prepared.proposals.first), plan = try catalogPlan(own)
    let gate = try active.apply(.gate(.init(proposalOrdinal: own.ordinal, proposedItem: own.item, dispatchPlan: plan,
                                            proof: .init(plan: plan, nativeSnapshot: .scalar(.null), authorization: .granted(directions: [.display]), safety: .passed),
                                            currentScope: plan.scope, currentNativeSnapshot: .scalar(.null))))
    let tree = try JSONDecoder().decode(ScenarioPayload.self, from: SchedulerTraceCodec.encodeStep(gate))
    guard case var .object(root) = tree, case var .object(state) = root["state"], case var .array(ready) = state["awaiting_receipt"],
          case var .object(entry) = ready[0], case var .object(encodedPlan) = entry["plan"] else { Issue.record("actual nested plan required"); return }
    encodedPlan.removeValue(forKey: "origin"); entry["plan"] = .object(encodedPlan); ready[0] = .object(entry); state["awaiting_receipt"] = .array(ready); root["state"] = .object(state)
    let record = try #require(active.records.last)
    var corrupt = active.records; corrupt[corrupt.count - 1] = try .init(node: record.node, predecessor: record.predecessor, input: record.input, step: active.catalog.intern(.object(root)))
    #expect(throws: (any Error).self) { try FeedbackBranchReplay.validate(corrupt, catalog: &active.catalog) }
}

@Test func feedbackCatalogEachDefinitionTypeHasExactKeysAndCanonicalScalarEncodings() throws {
    let valid = [#"{"kind":"catalog-node","id":"1","type":"null"}"#,
                 #"{"kind":"catalog-node","id":"1","type":"bool","value":true}"#,
                 #"{"kind":"catalog-node","id":"1","type":"number","bits":"0"}"#,
                 #"{"kind":"catalog-node","id":"1","type":"text","utf8":"YQ=="}"#,
                 #"{"kind":"catalog-node","id":"1","type":"array","children":[]}"#,
                 #"{"kind":"catalog-node","id":"1","type":"object","entries":[]}"#]
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    for raw in valid {
        var catalog = FeedbackTraceCatalog(); try catalog.readDefinition(Data(raw.utf8))
        let object = try FeedbackStrictJSON.object(Data(raw.utf8))
        for key in object.keys {
            var missing = object; missing.removeValue(forKey: key)
            #expect(throws: (any Error).self) { var value = FeedbackTraceCatalog(); try value.readDefinition(encoder.encode(ScenarioPayload.object(missing))) }
        }
        var extra = object; extra["unknown"] = .scalar(.null)
        #expect(throws: (any Error).self) { var value = FeedbackTraceCatalog(); try value.readDefinition(encoder.encode(ScenarioPayload.object(extra))) }
    }
    for bad in ["00", "+1", "-0", "1e0", "18446744073709551616"] {
        #expect(throws: (any Error).self) { try FeedbackStrictJSON.uint(.scalar(.text(bad))) }
    }
    #expect(throws: (any Error).self) { try FeedbackStrictJSON.uint(.scalar(.number(1))) }
    #expect(throws: (any Error).self) { try FeedbackStrictJSON.object(Data(#"{"id":"1","\u0069d":"2"}"#.utf8)) }
}

@Test func feedbackCatalogPersistedArtifactAuditUsesTheSameStrictReader() throws {
    var fixture = CatalogFixture(); _ = try fixture.apply(.initialize(.unlimited))
    var sample = try feedbackReadLines(feedbackV2Bytes(fixture)); #expect(try sample.replay().steps == 1)
}
