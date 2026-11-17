import Foundation
import SurfaceBindingContext
import SurfaceDeviceContracts
@testable import XTouchCompactCore

/// Original leaf semantics: a5324f7 CompactState and ParameterEngine, retained only in tests.
struct LegacyContextComparison: Equatable, Sendable, Codable {
    let operation: String
    let input: String
    let native: String
    let candidate: String
    var matches: Bool {
        native == candidate
    }
}

final class CompactContextAudit: @unchecked Sendable {
    private let lock = NSLock()
    private var records: [LegacyContextComparison] = []
    private var presentations: [Data: String] = [:]
    private var presentationBytes = 0
    private var presentationRequests = 0
    private var presentationFormats = 0
    private var presentationHits = 0

    /// Exact byte keys describe every original formatting input. Cache reuse never skips
    /// compare, precondition or a raw record; the builder is the unchanged reflection call.
    func presentation(key: Data, render: () -> String) -> String {
        lock.lock(); defer { lock.unlock() }
        presentationRequests += 1
        if let prior = presentations[key] {
            presentationHits += 1
            return prior
        }
        presentationFormats += 1
        let result = render()
        let bytes = key.count + result.utf8.count
        if presentations.count < 1024, bytes <= 1_048_576 - presentationBytes {
            presentations[key] = result
            presentationBytes += bytes
        }
        return result
    }

    var presentationMetrics: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return ["requests": presentationRequests, "formats": presentationFormats,
                "hits": presentationHits, "entries": presentations.count, "bytes": presentationBytes]
    }

    func compare(_ operation: String, input: String, native: String, candidate: String) {
        lock.lock(); defer { lock.unlock() }
        records.append(.init(operation: operation, input: input, native: native, candidate: candidate))
        #if DEBUG
            precondition(native == candidate, "J3 shadow mismatch in \(operation): native=\(native), candidate=\(candidate)")
        #endif
    }

    var comparisons: [LegacyContextComparison] {
        lock.lock(); defer { lock.unlock() }
        return records
    }
}

/// The self-test compiles exactly the declarations above, without a replacement checker.
extension CompactContextAudit: CompactContextAuditReader {
    var recordedComparisons: [CompactContextComparison] {
        comparisons.map { .init(operation: $0.operation, input: $0.input, native: $0.native, candidate: $0.candidate) }
    }
}

/// Length-delimited raw bytes, never String's canonical-equivalence equality or a digest.
/// Numeric encodings retain all bits. The scope DTO enumerates every stored field.
struct LegacyDisplayKey {
    private(set) var data: Data
    init(kind: UInt8) {
        data = Data([1, kind])
    }

    mutating func byte(_ value: UInt8) {
        data.append(value)
    }

    mutating func uint(_ value: UInt64) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    mutating func integer(_ value: Int) {
        uint(UInt64(bitPattern: Int64(value)))
    }

    mutating func string(_ value: String) {
        uint(UInt64(value.utf8.count)); data.append(contentsOf: value.utf8)
    }

    mutating func optionalString(_ value: String?) {
        guard let value else { byte(0); return }
        byte(1); string(value)
    }

    mutating func scope(_ value: CompactResourceScope?) {
        guard let value else { byte(0); return }
        byte(1)
        string(value.hostLayer.rawValue)
        optionalString(value.source?.rawValue)
        if let endpoint = value.endpoint {
            byte(1); optionalString(endpoint.endpointID); optionalString(endpoint.deviceID)
            uint(endpoint.connectionGeneration); string(endpoint.transportOrigin.rawValue)
        } else {
            byte(0)
        }
        byte(value.transmitChannel); byte(value.receiveChannel)
        string(value.lightProtocol)
        uint(value.bindingGeneration); uint(value.authorizationRouteGeneration)
    }
}

extension CompactContextAudit {
    func display(_ values: [Int]) -> String {
        var key = LegacyDisplayKey(kind: 1)
        key.uint(UInt64(values.count))
        for value in values {
            key.integer(value)
        }
        return presentation(key: key.data) { String(reflecting: values) }
    }

    func display(_ values: [String]) -> String {
        var key = LegacyDisplayKey(kind: 2)
        key.uint(UInt64(values.count))
        for value in values {
            key.string(value)
        }
        return presentation(key: key.data) { String(reflecting: values) }
    }

    func display(_ value: CompactResourceScope?) -> String {
        var key = LegacyDisplayKey(kind: 3)
        key.scope(value)
        return presentation(key: key.data) { String(reflecting: value) }
    }

    func display(_ value: CompactResourceMutation) -> String {
        var key = LegacyDisplayKey(kind: 4)
        switch value {
        case let .upsert(id, scope, payload):
            key.byte(1); key.integer(id); key.scope(scope); key.optionalString(payload)
        case let .remove(id): key.byte(2); key.integer(id)
        case .removeAll: key.byte(3)
        }
        return presentation(key: key.data) { String(reflecting: value) }
    }
}

struct LegacyResources: CompactResourceReference {
    let log = CompactContextAudit()
    private var ids: [String: Set<Int>] = [:]
    private var scopes: [String: [Int: CompactResourceScope]] = [:]
    private var values: [String: [Int: String]] = [:]
    var audit: any CompactContextAuditReader {
        log
    }

    private func check(_ registry: String, _ snapshot: CompactResourceSnapshot, phase: String) {
        // The original owner was a Set/dictionary, never a FIFO. Preserve actual order in input.
        log.compare(registry + "." + phase + ".ids", input: log.display(snapshot.ids), native: log.display(ids[registry, default: []].sorted()), candidate: log.display(snapshot.ids.sorted()))
        let old = ids[registry, default: []].sorted().map { "\($0):" + log.display(scopes[registry]?[$0]) }
        let next = snapshot.ids.sorted().map { "\($0):" + log.display(snapshot.scopes[$0]) }
        log.compare(registry + "." + phase + ".scopes", input: log.display(snapshot.ids), native: log.display(old), candidate: log.display(next))
    }

    mutating func apply(_ registry: String, event: CompactResourceMutation, before: CompactResourceSnapshot, after: CompactResourceSnapshot, removed: [Int]) {
        check(registry, before, phase: "before")
        var expectedRemoved: [Int] = []
        let operation: String
        switch event {
        case let .upsert(id, scope, value):
            ids[registry, default: []].insert(id)
            scopes[registry, default: [:]][id] = scope
            values[registry, default: [:]][id] = value
            operation = registry + ".insert"
        case let .remove(id):
            if ids[registry, default: []].remove(id) != nil {
                expectedRemoved = [id]
            }
            scopes[registry]?.removeValue(forKey: id); values[registry]?.removeValue(forKey: id)
            operation = registry + ".remove"
        case .removeAll:
            expectedRemoved = Array(ids[registry, default: []])
            ids[registry] = []; scopes[registry] = [:]; values[registry] = [:]
            operation = registry == "pending" ? "pending.removeAll.revoked" : registry + ".cache.invalidate"
        }
        log.compare(operation, input: log.display(event), native: log.display(expectedRemoved.sorted()), candidate: log.display(removed.sorted()))
        check(registry, after, phase: "after")
    }

    func read(_ registry: String, id: Int?, actual: String) {
        let expected: String = if let id {
            registry == "pending" ? String(ids[registry, default: []].contains(id)) : values[registry]?[id] ?? "nil"
        } else {
            log.display(ids[registry, default: []].sorted())
        }
        log.compare(registry + ".read", input: id.map(String.init) ?? "inventory", native: expected, candidate: actual)
    }

    mutating func reset() {
        ids = [:]; scopes = [:]; values = [:]
        log.compare("resource.reconfigured", input: "new empty validity owner", native: "empty", candidate: "empty")
    }
}

struct LegacyBindings: CompactBindingReference {
    let log = CompactContextAudit()
    private var configuration: SurfaceConfiguration = .neutral
    private var generation: UInt64 = 0
    var audit: any CompactContextAuditReader {
        log
    }

    mutating func configure(generation next: UInt64, changed: Bool) {
        log.compare("binding.context.changed", input: String(next), native: String(next != generation), candidate: String(changed))
        generation = next
    }

    mutating func replace(configuration next: SurfaceConfiguration) {
        configuration = next; generation = 0
    }

    func lookup(_ control: CompactControl, layer: CompactLayer, target: String?, action: ParameterAction?) {
        let reference = configuration.assignments.firstIndex { $0.control == control && $0.layer == layer }.map(String.init)
        let expected = configuration.assignments.first { $0.control == control && $0.layer == layer }?.action
        log.compare("binding.targetReference", input: control.neutralElementID + "|" + layer.rawValue, native: String(reflecting: reference), candidate: String(reflecting: target))
        log.compare("binding.lookup", input: control.neutralElementID + "|" + layer.rawValue, native: String(reflecting: expected), candidate: String(reflecting: action))
    }
}

func legacyReferences() -> CompactContextReferences {
    .init(resources: LegacyResources(), bindings: LegacyBindings())
}

func makeLegacySession(feedbackRecorder: FeedbackAuditRecorder? = nil, feedbackOwner: String = "core", feedbackSource: SurfaceDeviceContracts.DeviceSource = .simulation) throws -> CompactSession {
    var result: CompactSession = if let feedbackRecorder {
        try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual, feedbackAudit: feedbackRecorder,
                           feedbackSchedulerReference: TestFeedbackSchedulerReference(owner: feedbackOwner, source: feedbackSource, recorder: feedbackRecorder))
    } else {
        try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    }
    result.installContextReferences(legacyReferences())
    return result
}
