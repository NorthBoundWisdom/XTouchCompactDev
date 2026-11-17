import Foundation
import SurfaceDeviceConformance
import Testing
@testable import XTouchFeedbackTestSupport

private func firstExactTree(_ a: ScenarioPayload, _ b: ScenarioPayload, numbers: inout Int) -> Bool {
    switch (a, b) {
    case (.scalar(.null), .scalar(.null)): return true
    case let (.scalar(.flag(x)), .scalar(.flag(y))): return x == y
    case let (.scalar(.number(x)), .scalar(.number(y))): numbers += 1; return x.bitPattern == y.bitPattern
    case let (.scalar(.text(x)), .scalar(.text(y))): return x.utf8.elementsEqual(y.utf8)
    case let (.array(x), .array(y)):
        guard x.count == y.count else { return false }
        for (x, y) in zip(x, y) {
            if !firstExactTree(x, y, numbers: &numbers) {
                return false
            }
        }; return true
    case let (.object(x), .object(y)):
        let a = x.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }, b = y.keys.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        guard a.count == b.count else { return false }
        for (a, b) in zip(a, b) {
            guard a.utf8.elementsEqual(b.utf8), firstExactTree(x[a]!, y[b]!, numbers: &numbers) else { return false }
        }; return true
    default: return false
    }
}

@Test func feedbackFirstStrictASTKeepsEveryRawScalarBitAndLegacyInput() throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    var numbers = 0
    for raw in [#"{"a":-0,"b":0,"nfc":"é","nfd":"e\u0301","null":null,"bool":true}"#, #"[1.25,-1e20,0e99999999999999999999999999,"\uD83D\uDE00"]"#] {
        let bytes = Data(raw.utf8), old = try JSONDecoder().decode(ScenarioPayload.self, from: bytes), new = try SchedulerTraceCodec.decodePayload(bytes)
        #expect(firstExactTree(old, new, numbers: &numbers)); #expect(try encoder.encode(old) == encoder.encode(new))
    }
    for raw in [#"{"a":1,"a":2}"#, #"{"a":1,"\u0061":2}"#, "1e9999", "[1,]", "{\"a\":01}", "[NaN]", "true false", "\"\\uD800\""] {
        #expect(throws: (any Error).self) { try SchedulerTraceCodec.decodePayload(Data(raw.utf8)) }
    }
    #expect(numbers > 0)
    guard let directory = ProcessInfo.processInfo.environment["XTOUCH_J4_MIGRATION_INPUT_ROOT"] else { return }
    let root = URL(fileURLWithPath: directory)
    var fileCount = 0, lines = 0, inputs = 0, largest = 0
    for file in try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter({ $0.pathExtension == "jsonl" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
        let reader = try FeedbackCatalogLines(file)
        while let bytes = try reader.next() {
            largest = max(largest, bytes.count); #expect(bytes.count <= 1_048_576)
            let old = try JSONDecoder().decode(ScenarioPayload.self, from: bytes), new = try SchedulerTraceCodec.decodePayload(bytes)
            #expect(firstExactTree(old, new, numbers: &numbers)); #expect(try encoder.encode(old) == encoder.encode(new)); lines += 1
        }
        var document = try FeedbackCatalogDocument.read(file)
        for record in document.records {
            let bytes = try document.catalog.canonicalData(record.input)
            let old = try SchedulerTraceCodec.decodeInput(bytes)
            let new = try SchedulerTraceCodec.decodeInput(payload: SchedulerTraceCodec.decodePayload(bytes))
            let oldBytes = try SchedulerTraceCodec.encodeInput(old), newBytes = try SchedulerTraceCodec.encodeInput(new)
            #expect(oldBytes == bytes); #expect(newBytes == oldBytes)
            #expect(try firstExactTree(JSONDecoder().decode(ScenarioPayload.self, from: oldBytes), SchedulerTraceCodec.decodePayload(newBytes), numbers: &numbers))
            inputs += 1
        }
        fileCount += 1
    }
    #expect(fileCount == 77); #expect(inputs == 19434)
    print("FIRST_MIGRATION files=\(fileCount) raw_lines=\(lines) inputs=\(inputs) max_line_bytes=\(largest) exact_number_checks=\(numbers) all_bytes_equal=true")
}

@Test func feedbackFirstCanonicalBytesAreBoundedExactAndValueIsolated() throws {
    var catalog = FeedbackTraceCatalog()
    let first = try catalog.intern(.scalar(.text(String(repeating: "x", count: 3 * 1024 * 1024))))
    let original = try catalog.canonicalData(first)
    var branch = catalog
    let second = try catalog.intern(.scalar(.text(String(repeating: "y", count: 3 * 1024 * 1024))))
    let third = try catalog.intern(.scalar(.text(String(repeating: "z", count: 3 * 1024 * 1024))))
    _ = try catalog.canonicalData(second); _ = try catalog.canonicalData(third)
    #expect(catalog.canonicalByteCount <= FeedbackTraceCatalog.canonicalByteLimit)
    #expect(try catalog.canonicalData(first) == original)
    let different = try branch.intern(.scalar(.text("same-new-node-different-branch")))
    #expect(different == second)
    #expect(try branch.canonicalData(different) != catalog.canonicalData(second))
    #expect(throws: (any Error).self) { try branch.canonicalData(branch.nodes.count + 1) }
    #expect(branch.canonicalByteCount <= FeedbackTraceCatalog.canonicalByteLimit)
}

@Test func feedbackFirstLayoutCacheChecksActualTypeBeforeReusingAnExactComponent() throws {
    let item = try SchedulerItem(key: "layout", value: .scalar(.number(0)), scope: .scalar(.null))
    var catalog = FeedbackTraceCatalog()
    _ = try catalog.item(item)
    let count = catalog.representationCounts["layout_types"]
    _ = try catalog.item(item)
    #expect(catalog.representationCounts["layout_types"] == count)
    var missingField = FeedbackTraceCatalog()
    #expect(throws: (any Error).self) { try missingField.checkStored(item, id: "item", fields: ["key", "scope"]) }
    struct NewUnrepresentedField { let key: String; let value: Double; let scope: String; let added: Bool }
    #expect(throws: (any Error).self) {
        try catalog.checkStored(NewUnrepresentedField(key: "layout", value: 0, scope: "scope", added: true), id: "item", fields: ["key", "value", "scope"])
    }
}

@Test func feedbackFirstOptimizedSupportStillTrapsOnRealInvalidOccurrence() throws {
    let marker = "XTOUCH_FIRST_ASSERT_CHILD"
    if ProcessInfo.processInfo.environment[marker] == "1" {
        let recorder = FeedbackAuditRecorder()
        var reference = TestFeedbackSchedulerReference(owner: "assert-probe", source: .simulation, recorder: recorder)
        reference.generated([.noteOn(channel: 0, number: 1, velocity: 1)], scope: .init(), provenance: [])
        return
    }
    let executable = try #require(Bundle.main.executableURL)
    var arguments = Array(ProcessInfo.processInfo.arguments.dropFirst())
    if let index = arguments.firstIndex(of: "--filter") {
        arguments.removeSubrange(index ... index + 1)
    }
    arguments += ["--filter", "feedbackFirstOptimizedSupportStillTrapsOnRealInvalidOccurrence"]
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("xtouch-support-assert-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let logURL = root.appendingPathComponent("child.log")
    #expect(FileManager.default.createFile(atPath: logURL.path, contents: nil))
    let output = try FileHandle(forWritingTo: logURL)
    let process = Process(); process.executableURL = executable; process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment[marker] = "1"; environment["SWIFT_BACKTRACE"] = "enable=no"
    process.environment = environment; process.standardOutput = output; process.standardError = output
    try process.run()
    let deadline = ProcessInfo.processInfo.systemUptime + 10
    while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
        Thread.sleep(forTimeInterval: 0.01)
    }
    let timedOut = process.isRunning
    if timedOut {
        process.terminate()
    }
    process.waitUntilExit(); try output.close()
    let evidence = try String(contentsOf: logURL, encoding: .utf8)
    print("FIRST_ASSERT_PROBE executable=\(executable.lastPathComponent) exit=\(process.terminationStatus) reason=\(process.terminationReason.rawValue) timed_out=\(timedOut) evidence=\(logURL.path)")
    #expect(!timedOut); #expect(process.terminationReason == .uncaughtSignal)
    #expect(process.terminationStatus != 0)
    #expect(evidence.contains("complete feedback occurrence provenance"))
}

private func firstAuthorizationMembers(_ payload: ScenarioPayload?) -> [String]? {
    guard case let .scalar(.text(value)) = payload else { return nil }
    let prefix = "SurfaceFeedbackPlanning.PlanAuthorization.granted(directions: Set([", suffix = "]))"
    guard value.hasPrefix(prefix), value.hasSuffix(suffix) else { return nil }
    let body = String(value.dropFirst(prefix.count).dropLast(suffix.count))
    let members = body.isEmpty ? [] : body.components(separatedBy: ", ")
    let allowed = Set(["display", "mechanism", "management", "query"].map { "SurfaceDeviceContracts.EffectDirection." + $0 })
    guard members.allSatisfy({ allowed.contains($0) }), Set(members).count == members.count else { return nil }
    return members.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
}

@Test func feedbackFirstFullArtifactComparisonRetainsEveryFieldAndOriginalLineage() throws {
    var checkedNumbers = 0
    #expect(!firstExactTree(.scalar(.number(0)), .scalar(.number(-0.0)), numbers: &checkedNumbers))
    #expect(!firstExactTree(.scalar(.text("é")), .scalar(.text("e\u{301}")), numbers: &checkedNumbers))
    let environment = ProcessInfo.processInfo.environment
    guard let input = environment["XTOUCH_J4_COMPARISON_INPUT_ROOT"], let baseline = environment["XTOUCH_J4_COMPARISON_BASELINE_ROOT"] else { return }
    let root = URL(fileURLWithPath: input), oldRoot = URL(fileURLWithPath: baseline)
    let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    var byteDifferences = 0
    var rows = 0, inputs = 0, outputs = 0, strict = 0, setDifferences: [[String: Any]] = []
    for file in files {
        var current = try FeedbackCatalogDocument.read(file), old = try FeedbackCatalogDocument.read(oldRoot.appendingPathComponent(file.lastPathComponent))
        #expect(current.lineage == old.lineage); #expect(current.events.count == old.events.count)
        for (index, pair) in zip(current.events, old.events).enumerated() {
            rows += 1
            switch pair {
            case let (.scheduler(a), .scheduler(b)):
                #expect(a.node == b.node); #expect(a.predecessor == b.predecessor)
                let inputEqual = try current.catalog.canonicalData(a.input) == old.catalog.canonicalData(b.input)
                let stepEqual = try current.catalog.canonicalData(a.step) == old.catalog.canonicalData(b.step)
                if !inputEqual {
                    byteDifferences += 1
                }; if !stepEqual {
                    byteDifferences += 1
                }
                #expect(inputEqual); #expect(stepEqual)
                inputs += 1; outputs += 1
            case let (.raw(a), .raw(b)):
                var newValue = try FeedbackStrictJSON.object(a), oldValue = try FeedbackStrictJSON.object(b)
                if try FeedbackStrictJSON.text(newValue["kind"]) == "strict-plan" {
                    strict += 1
                }
                var numbers = 0
                if firstExactTree(.object(newValue), .object(oldValue), numbers: &numbers) {
                    continue
                }
                let newAuthorization = try FeedbackStrictJSON.text(newValue["proof_authorization"]), oldAuthorization = try FeedbackStrictJSON.text(oldValue["proof_authorization"])
                #expect(firstAuthorizationMembers(newValue["proof_authorization"]) != nil)
                #expect(firstAuthorizationMembers(newValue["proof_authorization"]) == firstAuthorizationMembers(oldValue["proof_authorization"]))
                newValue.removeValue(forKey: "proof_authorization"); oldValue.removeValue(forKey: "proof_authorization")
                #expect(firstExactTree(.object(newValue), .object(oldValue), numbers: &numbers))
                setDifferences.append(["file": file.lastPathComponent, "event": index + 1, "field": "proof_authorization", "old": oldAuthorization, "new": newAuthorization])
            default: Issue.record("event kind or order changed at \(file.lastPathComponent):\(index + 1)")
            }
        }
    }
    if let count = environment["XTOUCH_J4_COMPARISON_EXPECT_FILES"].flatMap(Int.init) {
        #expect(files.count == count)
    }
    let result: [String: Any] = ["files": files.count, "events": rows, "inputs": inputs, "whole_steps": outputs, "strict_plan_rows": strict,
                                 "scheduler_byte_differences": byteDifferences, "set_reflection_differences": setDifferences]
    let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
    if let output = environment["XTOUCH_J4_COMPARISON_PROOF"] {
        let url = URL(fileURLWithPath: output)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try data.write(to: url, options: .withoutOverwriting)
    }
    print("FIRST_ARTIFACT_COMPARISON files=\(files.count) events=\(rows) inputs=\(inputs) whole_steps=\(outputs) strict=\(strict) set_reflection_rows=\(setDifferences.count)")
}
