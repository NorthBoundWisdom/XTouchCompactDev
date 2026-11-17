import Foundation
import SurfaceDeviceConformance
import SurfaceFeedbackPlanning

/// Exact content keys, not semantic String equality or digest-only identity.
/// Node references are diagnostics only; host identities/times remain values.
struct FeedbackTraceCatalog {
    enum Failure: Error { case missingReference, malformed, duplicateDefinition, nonfinite, inputMismatch, layout }
    enum Node {
        case scalar(TraceValue)
        case array([Int])
        case object([(String, Int)])
    }

    private(set) var nodes: [Node] = []
    private var indices: [Data: Int] = [:]
    private var checkedLayouts: Set<String> = []
    private var lastItems: [Int: (SchedulerItem, Int)] = [:]
    private var lastPlans: [Int: (SchedulerTracePlan, Int)] = [:]
    private var lastProposals: [UInt64: (SchedulerProposal, Int)] = [:]
    private(set) var itemMemoHits = 0
    private(set) var itemMemoMisses = 0
    private(set) var planMemoHits = 0
    private(set) var planMemoMisses = 0
    private(set) var proposalMemoHits = 0
    private(set) var proposalMemoMisses = 0
    private(set) var canonicalHits = 0
    private(set) var canonicalMisses = 0
    private var checkedTypes: Set<ObjectIdentifier> = []
    private var canonicalBytes: [Int: Data] = [:]
    private(set) var canonicalByteCount = 0
    static let canonicalByteLimit = 8 * 1024 * 1024
    private let encoder: JSONEncoder = { let value = JSONEncoder(); value.outputFormatting = [.sortedKeys]; return value }()

    private func uint(_ value: UInt64, into data: inout Data) {
        var big = value.bigEndian; withUnsafeBytes(of: &big) { data.append(contentsOf: $0) }
    }

    private func text(_ value: String, into data: inout Data) {
        let bytes = Data(value.utf8); uint(UInt64(bytes.count), into: &data); data.append(bytes)
    }

    mutating func intern(_ value: ScenarioPayload) throws -> Int {
        var key = Data(); let node: Node
        switch value {
        case let .scalar(scalar):
            node = .scalar(scalar)
            switch scalar {
            case .null: key.append(0)
            case let .flag(value): key.append(1); key.append(value ? 1 : 0)
            case let .number(value):
                guard value.isFinite else { throw Failure.nonfinite }
                key.append(2); uint(value.bitPattern, into: &key)
            case let .text(value): key.append(3); text(value, into: &key)
            }
        case let .array(values):
            let references = try values.map { try intern($0) }; node = .array(references)
            key.append(4); uint(UInt64(references.count), into: &key)
            for reference in references {
                uint(UInt64(reference), into: &key)
            }
        case let .object(values):
            // Objects are unordered. All actual arrays retain their original order.
            let keys = values.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
            var entries: [(String, Int)] = []
            key.append(5); uint(UInt64(keys.count), into: &key)
            for name in keys {
                let reference = try intern(values[name]!); entries.append((name, reference))
                text(name, into: &key); uint(UInt64(reference), into: &key)
            }
            node = .object(entries)
        }
        return store(node, key: key)
    }

    private mutating func store(_ node: Node, key: Data) -> Int {
        if let existing = indices[key] {
            return existing
        }
        nodes.append(node); let reference = nodes.count; indices[key] = reference
        return reference
    }

    mutating func array(_ values: [Int]) -> Int {
        var key = Data([4]); uint(UInt64(values.count), into: &key)
        for value in values {
            uint(UInt64(value), into: &key)
        }
        return store(.array(values), key: key)
    }

    mutating func object(_ values: [String: Int]) -> Int {
        let names = values.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        var key = Data([5]); uint(UInt64(names.count), into: &key)
        for name in names {
            text(name, into: &key); uint(UInt64(values[name]!), into: &key)
        }
        return store(.object(names.map { ($0, values[$0]!) }), key: key)
    }

    func expand(_ reference: Int) throws -> ScenarioPayload {
        guard reference > 0, reference <= nodes.count else { throw Failure.missingReference }
        switch nodes[reference - 1] {
        case let .scalar(value): return .scalar(value)
        case let .array(values): return try .array(values.map(expand))
        case let .object(entries):
            var result: [String: ScenarioPayload] = [:]
            for (key, value) in entries {
                result[key] = try expand(value)
            }
            return .object(result)
        }
    }

    mutating func canonicalData(_ reference: Int) throws -> Data {
        guard reference > 0, reference <= nodes.count else { throw Failure.missingReference }
        if let bytes = canonicalBytes[reference] {
            canonicalHits += 1; return bytes
        }
        canonicalMisses += 1
        let bytes = try encoder.encode(expand(reference))
        if bytes.count <= Self.canonicalByteLimit {
            if canonicalByteCount + bytes.count > Self.canonicalByteLimit {
                canonicalBytes.removeAll(keepingCapacity: true); canonicalByteCount = 0
            }
            canonicalBytes[reference] = bytes; canonicalByteCount += bytes.count
        }
        return bytes
    }

    func definition(_ reference: Int) throws -> Data {
        guard reference > 0, reference <= nodes.count else { throw Failure.missingReference }
        var fields: [String: ScenarioPayload] = ["kind": .scalar(.text("catalog-node")), "id": .scalar(.text(String(reference)))]
        switch nodes[reference - 1] {
        case let .scalar(value):
            switch value {
            case .null: fields["type"] = .scalar(.text("null"))
            case let .flag(value): fields["type"] = .scalar(.text("bool")); fields["value"] = .scalar(.flag(value))
            case let .number(value): fields["type"] = .scalar(.text("number")); fields["bits"] = .scalar(.text(String(value.bitPattern)))
            case let .text(value): fields["type"] = .scalar(.text("text")); fields["utf8"] = .scalar(.text(Data(value.utf8).base64EncodedString()))
            }
        case let .array(values): fields["type"] = .scalar(.text("array")); fields["children"] = .array(values.map { .scalar(.text(String($0))) })
        case let .object(entries):
            fields["type"] = .scalar(.text("object"))
            fields["entries"] = .array(entries.map { .array([.scalar(.text(Data($0.0.utf8).base64EncodedString())), .scalar(.text(String($0.1)))]) })
        }
        return try encoder.encode(ScenarioPayload.object(fields))
    }

    mutating func readDefinition(_ data: Data) throws {
        try readDefinitionObject(FeedbackStrictJSON.object(data))
    }

    mutating func readDefinitionObject(_ value: [String: ScenarioPayload]) throws {
        let id = try FeedbackStrictJSON.integer(value["id"], positive: true)
        guard try FeedbackStrictJSON.text(value["kind"]) == "catalog-node", id == nodes.count + 1 else { throw Failure.duplicateDefinition }
        let type = try FeedbackStrictJSON.text(value["type"]); let node: Node
        func fields(_ extra: Set<String>) throws {
            try FeedbackStrictJSON.fields(value, extra.union(["kind", "id", "type"]))
        }
        func reference(_ value: ScenarioPayload) throws -> Int {
            let ref = try FeedbackStrictJSON.integer(value, positive: true)
            guard ref < id else { throw Failure.missingReference }; return ref
        }
        var key = Data()
        switch type {
        case "null": try fields([]); node = .scalar(.null); key.append(0)
        case "bool":
            try fields(["value"]); guard case let .scalar(.flag(flag)) = value["value"] else { throw Failure.malformed }
            node = .scalar(.flag(flag)); key.append(1); key.append(flag ? 1 : 0)
        case "number":
            try fields(["bits"]); let bits = try FeedbackStrictJSON.uint(value["bits"])
            let number = Double(bitPattern: bits); guard number.isFinite else { throw Failure.nonfinite }
            node = .scalar(.number(number)); key.append(2); uint(bits, into: &key)
        case "text":
            try fields(["utf8"]); let bytes = try FeedbackStrictJSON.base64(value["utf8"])
            guard let value = String(data: bytes, encoding: .utf8), Data(value.utf8) == bytes else { throw Failure.malformed }
            node = .scalar(.text(value)); key.append(3); text(value, into: &key)
        case "array":
            try fields(["children"]); let refs = try FeedbackStrictJSON.array(value["children"]).map(reference)
            node = .array(refs); key.append(4); uint(UInt64(refs.count), into: &key)
            for ref in refs {
                uint(UInt64(ref), into: &key)
            }
        case "object":
            try fields(["entries"]); let entries = try FeedbackStrictJSON.array(value["entries"])
            var result: [(String, Int)] = [], names: Set<String> = []
            key.append(5); uint(UInt64(entries.count), into: &key)
            for value in entries {
                let pair = try FeedbackStrictJSON.array(value); guard pair.count == 2 else { throw Failure.malformed }
                let bytes = try FeedbackStrictJSON.base64(pair[0])
                guard let name = String(data: bytes, encoding: .utf8), Data(name.utf8) == bytes, names.insert(name).inserted else { throw Failure.malformed }
                if let previous = result.last?.0 {
                    guard previous.utf8.lexicographicallyPrecedes(name.utf8) else { throw Failure.malformed }
                }
                let ref = try reference(pair[1]); result.append((name, ref))
                text(name, into: &key); uint(UInt64(ref), into: &key)
            }
            node = .object(result)
        default: throw Failure.malformed
        }
        guard indices[key] == nil else { throw Failure.duplicateDefinition }
        nodes.append(node); indices[key] = id
    }
}

/// A full output DTO, not a projection. State and plan/item values come from the
/// pinned public codec; every remaining 49ad output field is explicitly retained.
enum FeedbackStepPayload {
    static func requireLayout(_ actual: Set<String>, _ expected: Set<String>) throws {
        guard actual == expected else { throw FeedbackTraceCatalog.Failure.layout }
    }

    private static func text(_ value: String) -> ScenarioPayload {
        .scalar(.text(value))
    }

    private static func strings(_ values: [String]) -> ScenarioPayload {
        .array(values.map(text))
    }

    private static func proposal(_ value: SchedulerProposal) -> ScenarioPayload {
        .object(["ordinal": text(String(value.ordinal)), "cause_ordinal": text(String(value.causeOrdinal)), "cause": text(value.cause.rawValue), "item": SchedulerTraceCodec.itemPayload(value.item)])
    }

    fileprivate static func preflight(_ result: FeedbackPreflight) -> ScenarioPayload {
        if case .permitted = result {
            return .object(["state": text("permitted")])
        }
        guard case let .rejected(reason) = result else { preconditionFailure("closed preflight") }
        var value: [String: ScenarioPayload] = ["state": text("rejected")]
        switch reason {
        case .planMismatch: value["reason"] = text("plan_mismatch")
        case .staleScope: value["reason"] = text("stale_scope")
        case .staleNativeProof: value["reason"] = text("stale_native_proof")
        case let .authorizationDenied(reason): value["reason"] = text("authorization_denied"); value["native_reason"] = text(reason)
        case let .wrongDirections(missing, surplus): value["reason"] = text("wrong_directions"); value["missing"] = strings(missing.map(\.rawValue).sorted()); value["surplus"] = strings(surplus.map(\.rawValue).sorted())
        case let .nativeRejected(reason): value["reason"] = text("native_rejected"); value["native_reason"] = text(reason)
        }
        return .object(value)
    }

    fileprivate static func result(_ value: FeedbackAttemptResult) -> ScenarioPayload {
        switch value {
        case .accepted: .object(["state": text("accepted")])
        case let .rejected(reason): .object(["state": text("rejected"), "reason": text(reason)])
        case let .notAttempted(reason): .object(["state": text("not_attempted"), "reason": text(reason)])
        }
    }

    static func checkLayout(_ step: SchedulerStep) {
        precondition(Set(Mirror(reflecting: step).children.compactMap(\.label)) == ["input", "snapshot", "proposals", "removedKeys", "replacedKeys", "deduplicatedKeys", "gateDecisions", "receipts", "alignmentDifferences"], "new unrepresented step field")
        precondition(Set(Mirror(reflecting: step.snapshot).children.compactMap(\.label)) == ["owner", "inputOrdinal", "rate", "queued", "withheld", "desired", "acceptedCache", "awaitingGate", "awaitingReceipt", "tokens", "lastRefill", "retryAfter", "persistentAlignmentDifferences"], "new unrepresented state field")
    }

    static func make(_ step: SchedulerStep, input: ScenarioPayload) -> ScenarioPayload {
        checkLayout(step)
        return .object(["artifact": text("scheduler_candidate_output_v1"), "input": input,
                        "state": SchedulerTraceCodec.statePayload(step.snapshot), "proposals": .array(step.proposals.map(proposal)),
                        "removed_keys": strings(step.removedKeys), "replaced_keys": strings(step.replacedKeys), "deduplicated_keys": strings(step.deduplicatedKeys),
                        "gates": .array(step.gateDecisions.map { .object(["proposal": text(String($0.proposalOrdinal)), "result": preflight($0.result)]) }),
                        "receipts": .array(step.receipts.map { .object(["proposal": $0.proposalOrdinal.map { text(String($0)) } ?? .scalar(.null),
                                                                        "item": SchedulerTraceCodec.itemPayload($0.receipt.item), "plan": SchedulerTraceCodec.planPayload($0.receipt.dispatchPlan),
                                                                        "result": result($0.receipt.result), "current_scope_matches": $0.currentScopeMatches.map { .scalar(.flag($0)) } ?? .scalar(.null)]) }),
                        "alignment_differences": strings(step.alignmentDifferences)])
    }
}

struct FeedbackSchedulerRecord {
    let node: Int
    let predecessor: Int?
    let input: Int
    let step: Int
}

private func feedbackRecordPool<Result>(_ body: () throws -> Result) rethrows -> Result {
    #if canImport(ObjectiveC)
        try autoreleasepool(invoking: body)
    #else
        try body()
    #endif
}

enum FeedbackBranchReplay {
    enum Failure: Error { case missingParent, outputMismatch, identity }
    static func checkIdentity(_ lineage: [FeedbackLineage]) throws {
        for (index, value) in lineage.enumerated() {
            guard value.node == index + 1, value.parent.map({ $0 > 0 && $0 < value.node }) ?? true else { throw Failure.identity }
        }
    }

    static func validate(_ records: [FeedbackSchedulerRecord], catalog: inout FeedbackTraceCatalog, declared: [FeedbackLineage]? = nil) throws -> (steps: Int, peakStates: Int) {
        let actual = records.map { FeedbackLineage(node: $0.node, parent: $0.predecessor) }
        try checkIdentity(actual)
        if let declared {
            try checkIdentity(declared); guard declared == actual else { throw FeedbackStrictJSON.Failure.identity }
        }
        var remaining: [Int: Int] = [:]
        for record in records {
            if let parent = record.predecessor {
                remaining[parent, default: 0] += 1
            }
        }
        var frontier: [Int: SchedulerCandidate] = [:]; var peak = 0
        for record in records {
            var candidate: SchedulerCandidate
            if let parent = record.predecessor {
                guard let value = frontier[parent] else { throw Failure.missingParent }
                candidate = value
            } else {
                candidate = SchedulerCandidate()
            }
            try feedbackRecordPool {
                let inputBytes = try catalog.canonicalData(record.input)
                let input = try SchedulerTraceCodec.decodeInput(payload: SchedulerTraceCodec.decodePayload(inputBytes))
                let actual = try candidate.apply(input)
                guard try catalog.step(actual, input: record.input) == record.step else { throw Failure.outputMismatch }
            }
            if remaining[record.node, default: 0] > 0 {
                frontier[record.node] = candidate
            }
            if let parent = record.predecessor {
                remaining[parent, default: 0] -= 1
                if remaining[parent] == 0 {
                    frontier.removeValue(forKey: parent)
                }
            }
            peak = max(peak, frontier.count)
        }
        return (records.count, peak)
    }
}

private func feedbackExactText(_ lhs: String, _ rhs: String) -> Bool {
    let quick = lhs.utf8.withContiguousStorageIfAvailable { a in
        rhs.utf8.withContiguousStorageIfAvailable { b -> Bool in
            guard a.count == b.count else { return false }
            if a.isEmpty || a.baseAddress == b.baseAddress {
                return true
            }
            return memcmp(a.baseAddress!, b.baseAddress!, a.count) == 0
        }
    }
    if let nested = quick, let value = nested {
        return value
    }
    return lhs.utf8.elementsEqual(rhs.utf8)
}

private func feedbackExactPayload(_ lhs: ScenarioPayload, _ rhs: ScenarioPayload) -> Bool {
    switch (lhs, rhs) {
    case (.scalar(.null), .scalar(.null)): return true
    case let (.scalar(.flag(a)), .scalar(.flag(b))): return a == b
    case let (.scalar(.number(a)), .scalar(.number(b))): return a.bitPattern == b.bitPattern
    case let (.scalar(.text(a)), .scalar(.text(b))): return feedbackExactText(a, b)
    case let (.array(a), .array(b)): return a.count == b.count && zip(a, b).allSatisfy(feedbackExactPayload)
    case let (.object(a), .object(b)):
        guard a.count == b.count else { return false }
        for (name, value) in a {
            guard let index = b.index(forKey: name) else { return false }
            let (actualName, actualValue) = b[index]
            guard feedbackExactText(name, actualName), feedbackExactPayload(value, actualValue) else { return false }
        }
        return true
    default: return false
    }
}

private func feedbackExactOptionalText(_ lhs: String?, _ rhs: String?) -> Bool {
    switch (lhs, rhs) { case (nil, nil): true; case let (.some(a), .some(b)): feedbackExactText(a, b); default: false }
}

private func feedbackExactItem(_ lhs: SchedulerItem, _ rhs: SchedulerItem) -> Bool {
    feedbackExactText(lhs.key, rhs.key) && feedbackExactPayload(lhs.value, rhs.value) && feedbackExactPayload(lhs.scope, rhs.scope)
}

private func feedbackExactPlan(_ lhs: SchedulerTracePlan, _ rhs: SchedulerTracePlan) -> Bool {
    guard feedbackExactPayload(lhs.reference, rhs.reference), feedbackExactPayload(lhs.payload, rhs.payload),
          feedbackExactPayload(lhs.origin, rhs.origin), feedbackExactPayload(lhs.scope, rhs.scope),
          feedbackExactPayload(lhs.capturedEvidence, rhs.capturedEvidence), lhs.source == rhs.source,
          feedbackExactOptionalText(lhs.endpointEvidence.endpointID, rhs.endpointEvidence.endpointID),
          feedbackExactOptionalText(lhs.endpointEvidence.deviceID, rhs.endpointEvidence.deviceID),
          lhs.endpointEvidence.connectionGeneration == rhs.endpointEvidence.connectionGeneration,
          lhs.endpointEvidence.transportOrigin == rhs.endpointEvidence.transportOrigin,
          feedbackExactText(lhs.targetID, rhs.targetID), lhs.affectedElements.count == rhs.affectedElements.count,
          lhs.classification == rhs.classification, lhs.sideEffects == rhs.sideEffects, lhs.deliveryMode == rhs.deliveryMode else { return false }
    return lhs.affectedElements.allSatisfy { element in rhs.affectedElements.contains { feedbackExactText(element, $0) } }
}

extension FeedbackTraceCatalog {
    mutating func checkStored<Value>(_ value: Value, id _: String, fields: @autoclosure () -> Set<String>) throws {
        let type = ObjectIdentifier(Value.self)
        guard !checkedTypes.contains(type) else { return }
        try FeedbackStepPayload.requireLayout(Set(Mirror(reflecting: value).children.compactMap(\.label)), fields())
        checkedTypes.insert(type)
    }

    private mutating func string(_ value: String) throws -> Int {
        try intern(.scalar(.text(value)))
    }

    private mutating func strings(_ value: [String]) throws -> Int {
        try array(value.map { try string($0) })
    }

    private mutating func number(_ value: Double?) throws -> Int {
        try intern(value.map { .scalar(.number($0)) } ?? .scalar(.null))
    }

    mutating func item(_ value: SchedulerItem) throws -> Int {
        try checkStored(value, id: "item", fields: ["key", "value", "scope"])
        if !checkedLayouts.contains("item-codec") {
            try FeedbackStrictJSON.fieldsObject(SchedulerTraceCodec.itemPayload(value), ["key", "value", "scope"]); checkedLayouts.insert("item-codec")
        }
        let key = try string(value.key)
        if let previous = lastItems[key], feedbackExactItem(previous.0, value) {
            itemMemoHits += 1; return previous.1
        }
        itemMemoMisses += 1
        let scope = try intern(value.scope), payload = try intern(value.value)
        let result = object(["key": key, "scope": scope, "value": payload])
        lastItems[key] = (value, result); return result
    }

    mutating func plan(_ value: SchedulerTracePlan) throws -> Int {
        try checkStored(value, id: "plan", fields: ["reference", "payload", "origin", "scope", "source", "endpointEvidence", "capturedEvidence", "targetID", "affectedElements", "classification", "sideEffects", "deliveryMode"])
        try checkStored(value.endpointEvidence, id: "endpoint", fields: ["endpointID", "deviceID", "connectionGeneration", "transportOrigin"])
        if !checkedLayouts.contains("plan-codec") {
            try FeedbackStrictJSON.fieldsObject(SchedulerTraceCodec.planPayload(value), ["reference", "payload", "origin", "scope", "source", "endpoint", "evidence", "target", "affected_elements", "classification", "side_effects", "delivery"]); checkedLayouts.insert("plan-codec")
        }
        // Every field participates in the existing exact Data/node key. No
        // reference/ordinal bucket, historical value scan, or semantic equality.
        let reference = try intern(value.reference)
        if let previous = lastPlans[reference], feedbackExactPlan(previous.0, value) {
            planMemoHits += 1; return previous.1
        }
        planMemoMisses += 1
        let elements = try strings(value.affectedElements.sorted())
        let classification = try string(value.classification.rawValue)
        let delivery = try string(value.deliveryMode == .direct ? "direct" : "coalescible")
        let generation = try string(String(value.endpointEvidence.connectionGeneration))
        let device = try intern(value.endpointEvidence.deviceID.map { .scalar(.text($0)) } ?? .scalar(.null))
        let endpointID = try intern(value.endpointEvidence.endpointID.map { .scalar(.text($0)) } ?? .scalar(.null))
        let transport = try string(value.endpointEvidence.transportOrigin.rawValue)
        let endpoint = object(["connection_generation": generation, "device_id": device, "endpoint_id": endpointID, "origin": transport])
        let evidence = try intern(value.capturedEvidence), origin = try intern(value.origin), payload = try intern(value.payload)
        let scope = try intern(value.scope), effects = try strings(value.sideEffects.map(\.rawValue).sorted())
        let source = try string(value.source.rawValue), target = try string(value.targetID)
        let result = object(["affected_elements": elements, "classification": classification, "delivery": delivery, "endpoint": endpoint,
                             "evidence": evidence, "origin": origin, "payload": payload, "reference": reference, "scope": scope,
                             "side_effects": effects, "source": source, "target": target])
        lastPlans[reference] = (value, result); return result
    }

    private mutating func proposal(_ value: SchedulerProposal) throws -> Int {
        try checkStored(value, id: "proposal", fields: ["ordinal", "causeOrdinal", "cause", "item"])
        if let previous = lastProposals[value.ordinal], previous.0.ordinal == value.ordinal,
           previous.0.causeOrdinal == value.causeOrdinal, previous.0.cause == value.cause,
           feedbackExactItem(previous.0.item, value.item)
        {
            proposalMemoHits += 1; return previous.1
        }
        proposalMemoMisses += 1
        let result = try object(["ordinal": string(String(value.ordinal)), "cause_ordinal": string(String(value.causeOrdinal)),
                                 "cause": string(value.cause.rawValue), "item": item(value.item)])
        lastProposals[value.ordinal] = (value, result); return result
    }

    private mutating func state(_ value: SchedulerStateSnapshot) throws -> Int {
        let rate: Int = switch value.rate {
        case nil: try intern(.scalar(.null))
        case .unlimited: try object(["kind": string("unlimited")])
        case let .bucket(perSecond, burst, cooldown): try object(["kind": string("bucket"), "per_second": intern(.scalar(.number(perSecond))), "burst": intern(.scalar(.number(Double(burst)))), "error_cooldown": intern(.scalar(.number(cooldown)))])
        }
        var desired: [String: Int] = [:], cache: [String: Int] = [:]
        for (key, value) in value.desired {
            desired[key] = try item(value)
        }
        for (key, value) in value.acceptedCache {
            cache[key] = try item(value)
        }
        let queued = try array(value.queued.map { try item($0) }), withheld = try array(value.withheld.map { try item($0) })
        let pending = try array(value.awaitingGate.map { try proposal($0) })
        let receipts = try array(value.awaitingReceipt.map { try object(["proposal": proposal($0.proposal), "plan": plan($0.plan)]) })
        return try object(["owner": intern(value.owner.map { .scalar(.text($0)) } ?? .scalar(.null)), "input_ordinal": string(String(value.inputOrdinal)), "rate": rate,
                           "queued": queued, "withheld": withheld, "desired": object(desired), "accepted_cache": object(cache),
                           "awaiting_gate": pending, "awaiting_receipt": receipts, "tokens": number(value.tokens), "last_refill": number(value.lastRefill),
                           "retry_after": number(value.retryAfter), "persistent_alignment_differences": strings(value.persistentAlignmentDifferences)])
    }

    var representationCounts: [String: Int] {
        ["item_hits": itemMemoHits, "item_misses": itemMemoMisses, "plan_hits": planMemoHits, "plan_misses": planMemoMisses,
         "proposal_hits": proposalMemoHits, "proposal_misses": proposalMemoMisses, "canonical_hits": canonicalHits,
         "canonical_misses": canonicalMisses, "layout_types": checkedTypes.count]
    }

    mutating func step(_ value: SchedulerStep, input: Int) throws -> Int {
        try checkStored(value.input, id: "envelope", fields: ["owner", "ordinal", "input", "context"])
        for ready in value.snapshot.awaitingReceipt {
            try checkStored(ready, id: "ready", fields: ["proposal", "plan"])
        }
        for gate in value.gateDecisions {
            try checkStored(gate, id: "gate-decision", fields: ["proposalOrdinal", "result"])
        }
        for receipt in value.receipts {
            try checkStored(receipt, id: "association", fields: ["proposalOrdinal", "receipt", "currentScopeMatches"])
            try checkStored(receipt.receipt, id: "actual-receipt", fields: ["item", "dispatchPlan", "result", "currentScope"])
        }
        switch value.input.input {
        case let .gate(gate):
            try checkStored(gate, id: "gate-record", fields: ["proposalOrdinal", "proposedItem", "dispatchPlan", "proof", "currentScope", "currentNativeSnapshot"])
            try checkStored(gate.proof, id: "proof", fields: ["plan", "nativeSnapshot", "authorization", "safety"])
        case let .receipt(receipt): try checkStored(receipt, id: "actual-receipt", fields: ["item", "dispatchPlan", "result", "currentScope"])
        default: break
        }
        guard try SchedulerTraceCodec.encodeInput(value.input) == canonicalData(input) else { throw Failure.inputMismatch }
        try checkStored(value, id: "step", fields: ["input", "snapshot", "proposals", "removedKeys", "replacedKeys", "deduplicatedKeys", "gateDecisions", "receipts", "alignmentDifferences"])
        try checkStored(value.snapshot, id: "state", fields: ["owner", "inputOrdinal", "rate", "queued", "withheld", "desired", "acceptedCache", "awaitingGate", "awaitingReceipt", "tokens", "lastRefill", "retryAfter", "persistentAlignmentDifferences"])
        let state = try state(value.snapshot)
        let proposals = try array(value.proposals.map { try proposal($0) })
        let gates = try array(value.gateDecisions.map { try object(["proposal": string(String($0.proposalOrdinal)), "result": intern(FeedbackStepPayload.preflight($0.result))]) })
        let receipts = try array(value.receipts.map { value in
            try object(["proposal": intern(value.proposalOrdinal.map { .scalar(.text(String($0))) } ?? .scalar(.null)),
                        "item": item(value.receipt.item), "plan": plan(value.receipt.dispatchPlan), "result": intern(FeedbackStepPayload.result(value.receipt.result)),
                        "current_scope_matches": intern(value.currentScopeMatches.map { .scalar(.flag($0)) } ?? .scalar(.null))])
        })
        return try object(["artifact": string("scheduler_candidate_output_v1"), "input": input, "state": state, "proposals": proposals,
                           "removed_keys": strings(value.removedKeys), "replaced_keys": strings(value.replacedKeys), "deduplicated_keys": strings(value.deduplicatedKeys),
                           "gates": gates, "receipts": receipts, "alignment_differences": strings(value.alignmentDifferences)])
    }
}
