import Foundation
import Testing
@testable import XTouchCompactCore

private func writeContextProof(_ name: String, audits: [(String, any CompactContextAuditReader)], facts: [[String: String]]) throws {
    let rows = audits.flatMap { group, audit in audit.recordedComparisons.map { (group, $0) } }
    #expect(!rows.isEmpty)
    let allMatch = rows.allSatisfy(\.1.matches)
    #expect(allMatch)
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["XTOUCH_J3_SHADOW_REPORT_ROOT"] ?? repo.appendingPathComponent("build/j/j3-shadow").path)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let encodedRows = try rows.map { group, value -> [String: Any] in
        var row = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        row["owner"] = group; row["matches"] = value.matches
        return row
    }
    try JSONSerialization.data(withJSONObject: ["comparisons": rows.count, "differences": rows.filter { !$0.1.matches }.count,
                                                "rows": encodedRows, "operation_facts": facts], options: [.prettyPrinted, .sortedKeys])
        .write(to: root.appendingPathComponent(name + ".json"))
    print("J3_CORE_SHADOW file=\(name) comparisons=\(rows.count) differences=\(rows.filter { !$0.1.matches }.count)")
}

@Test func actualDeferredAndDisplayRegistriesShadowExplicitSameContextAndReconnect() throws {
    var session = try makeLegacySession()
    var facts: [[String: String]] = []
    let stateAudit = try #require(session.state.contextAudit), bindingsAudit = try #require(session.parameters.contextAudit)
    _ = try session.connect(assertLayer: false)
    _ = try session.receive([.controlChange(channel: 0, number: 101, value: 127), .controlChange(channel: 0, number: 102, value: 127)])
    _ = try session.setParameter("a.Fader.2", value: 44)
    _ = try session.setParameter("a.Fader.1", value: 83)
    _ = try session.setParameter("a.Fader.2", value: 55)
    #expect(session.state.pendingMotorFacts.map(\.index) == [1, 2])
    facts.append(["operation": "defer-in-order-2-1-coalesce-2", "pending": String(reflecting: session.state.pendingMotorFacts)])
    _ = try session.selectHostLayer(.a)
    #expect(session.state.pendingMotorFacts.isEmpty)
    #expect(session.state.isTouched(1) && session.state.isTouched(2))
    _ = try session.setParameter("a.Fader.1", value: 84)
    #expect(session.state.isMotorPending(1))
    #expect(try session.connect(assertLayer: false).isEmpty)
    #expect(session.state.pendingMotorFacts.isEmpty)
    #expect(try session.connect(assertLayer: false).isEmpty)
    #expect(session.state.isTouched(1) && session.state.observedLayer == nil)
    facts.append(["operation": "same-context-and-repeated-physical-attach", "pending": String(reflecting: session.state.pendingMotorFacts), "touch": String(session.state.isTouched(1))])
    _ = try session.setDisplayRing(1, value: 11)
    _ = try session.receive([.controlChange(channel: 0, number: 10, value: 21)])
    _ = try session.setDisplayButton(34, light: .on)
    _ = try session.receive([.noteOn(channel: 0, number: 49, velocity: 127)])
    session.invalidateTransportFeedback()
    #expect(stateAudit.recordedComparisons.contains { $0.operation == "pending.removeAll.revoked" && $0.native == "[1, 2]" })
    try writeContextProof("deferred-cache-lifecycle", audits: [("state", stateAudit), ("bindings", bindingsAudit)], facts: facts)
}

@Test func bindingLookupAndRevisionShadowAllPhysicalRolesWithoutBorrowingValues() throws {
    var session = try makeLegacySession()
    let audit = try #require(session.parameters.contextAudit)
    var configuration = SurfaceConfiguration.neutral
    configuration.assignments += [.init(control: .button(9), layer: .a, action: .set("a.Fader.1", 19)),
                                  .init(control: .button(10), layer: .b, action: .step("b.Fader.1", 2)),
                                  .init(control: .footswitch, layer: .a, action: .resetGroup("Layer A"))]
    let oldGeneration = session.writeAuthorization.bindingGeneration
    _ = try session.loadConfiguration(configuration)
    #expect(session.writeAuthorization.bindingGeneration == oldGeneration + 1)
    for assignment in configuration.assignments {
        #expect(session.parameters.assignment(assignment.control, layer: assignment.layer) == assignment.action)
    }
    #expect(session.parameters.assignment(.expression, layer: .a) == nil)
    let generation = session.writeAuthorization.bindingGeneration
    configuration.parameters[0].name = "metadata edit"
    try session.replaceConfigurationKeepingValues(configuration)
    #expect(session.writeAuthorization.bindingGeneration == generation)
    _ = session.parameters.assignment(.button(9), layer: .a)
    _ = try session.loadConfiguration(configuration)
    #expect(session.writeAuthorization.bindingGeneration == generation + 1)
    #expect(audit.recordedComparisons.contains { $0.operation == "binding.targetReference" })
    try writeContextProof("binding-lookup-revision", audits: [("bindings", audit)], facts: [["old_generation": String(oldGeneration), "final_generation": String(session.writeAuthorization.bindingGeneration), "values": String(reflecting: session.parameters.values.sorted { $0.key < $1.key })]])
}

@Test func contextInvalidationRetainsPhysicalMismatchAndOldLayerReleaseSafety() throws {
    var session = try makeLegacySession()
    let audit = try #require(session.state.contextAudit)
    _ = try session.connect(assertLayer: false)
    _ = try session.receive([.controlChange(channel: 0, number: 101, value: 127)])
    _ = try session.setParameter("a.Fader.1", value: 91)
    #expect(session.state.isMotorPending(1))
    _ = try session.receive([.controlChange(channel: 0, number: 37, value: 41)])
    #expect(session.state.observedLayer == .b && session.state.layerMismatch)
    #expect(!session.state.isMotorPending(1))
    _ = try session.receive([.controlChange(channel: 0, number: 101, value: 0)])
    #expect(session.state.observedLayer == .b && session.state.layerMismatch)
    let feedback = try session.recallFaders()
    #expect(feedback.isEmpty)
    _ = try session.selectHostLayer(.a)
    #expect(session.state.observedLayer == .b && session.state.layerMismatch)
    #expect(try session.recallFaders().isEmpty)
    try writeContextProof("physical-evidence-retained", audits: [("state", audit)], facts: [["known_layer": session.state.observedLayer?.rawValue ?? "unknown", "mismatch": String(session.state.layerMismatch), "feedback": String(reflecting: feedback)]])
}

@Test func valueReferenceCandidateCopiesAndDiscardDoNotMutateCanonicalResourceOrBindings() throws {
    var canonical = try makeLegacySession()
    _ = try canonical.receive([.controlChange(channel: 0, number: 101, value: 127)])
    _ = try canonical.setParameter("a.Fader.1", value: 80)
    _ = try canonical.setDisplayRing(1, value: 20)
    let oldGeneration = canonical.writeAuthorization.bindingGeneration
    do {
        var candidate = canonical
        _ = try candidate.selectHostLayer(.b)
        var configuration = SurfaceConfiguration.neutral
        configuration.assignments[0].action = .parameter("a.Fader.2")
        _ = try candidate.loadConfiguration(configuration)
        candidate.invalidateTransportFeedback()
        #expect(candidate.state.pendingMotorFacts.isEmpty)
        #expect(candidate.writeAuthorization.bindingGeneration == oldGeneration + 1)
    }
    // Reads and later mutations must still use the original value oracle, not the discarded branch.
    #expect(canonical.state.isMotorPending(1))
    #expect(canonical.writeAuthorization.bindingGeneration == oldGeneration)
    #expect(canonical.parameters.assignment(.fader(1), layer: .a) == .parameter("a.Fader.1"))
    #expect(try canonical.setDisplayRing(1, value: 20).isEmpty)
    let release = try canonical.receive([.controlChange(channel: 0, number: 101, value: 0)])
    #expect(release.feedback.contains(.controlChange(channel: 0, number: 1, value: 80)))
    #expect(!canonical.state.isMotorPending(1))
    try writeContextProof("value-reference-copy-isolation", audits: [("state", #require(canonical.state.contextAudit)), ("bindings", #require(canonical.parameters.contextAudit))], facts: [["canonical_generation": String(oldGeneration), "candidate_discarded": "true", "canonical_release": String(reflecting: release.feedback)]])
}

@Test func defaultKernelOwnersAllocateNoLegacyReferenceOrDiagnosticHistory() throws {
    let session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    #expect(session.state.contextReference == nil)
    #expect(session.parameters.bindingReference == nil)
    #expect(session.state.contextAudit == nil && session.parameters.contextAudit == nil)
}
