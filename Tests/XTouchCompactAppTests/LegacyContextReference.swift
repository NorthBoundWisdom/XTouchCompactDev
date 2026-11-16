import Foundation
import SurfaceBindingContext
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
        log.compare(registry + "." + phase + ".ids", input: String(reflecting: snapshot.ids), native: String(reflecting: ids[registry, default: []].sorted()), candidate: String(reflecting: snapshot.ids.sorted()))
        let old = ids[registry, default: []].sorted().map { "\($0):" + String(reflecting: scopes[registry]?[$0]) }
        let next = snapshot.ids.sorted().map { "\($0):" + String(reflecting: snapshot.scopes[$0]) }
        log.compare(registry + "." + phase + ".scopes", input: String(reflecting: snapshot.ids), native: String(reflecting: old), candidate: String(reflecting: next))
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
        log.compare(operation, input: String(reflecting: event), native: String(reflecting: expectedRemoved.sorted()), candidate: String(reflecting: removed.sorted()))
        check(registry, after, phase: "after")
    }

    func read(_ registry: String, id: Int?, actual: String) {
        let expected: String = if let id {
            registry == "pending" ? String(ids[registry, default: []].contains(id)) : values[registry]?[id] ?? "nil"
        } else {
            String(reflecting: ids[registry, default: []].sorted())
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

func makeLegacySession() throws -> CompactSession {
    var result = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    result.installContextReferences(legacyReferences())
    return result
}
