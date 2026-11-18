import Foundation
import SurfaceDeviceConformance

/// Lexical duplicate-key rejection precedes the value decoder's last-key-wins behavior.
enum FeedbackStrictJSON {
    enum Failure: Error { case invalidJSON, duplicateKey, fields, type, decimal, reference, header, identity, coverage }
    static func object(_ data: Data) throws -> [String: ScenarioPayload] {
        guard case let .object(value) = try SchedulerTraceCodec.decodePayload(data) else { throw Failure.invalidJSON }
        return value
    }

    static func fieldsObject(_ payload: ScenarioPayload, _ expected: Set<String>) throws {
        guard case let .object(value) = payload else { throw Failure.type }; try fields(value, expected)
    }

    static func fields(_ value: [String: ScenarioPayload], _ expected: Set<String>) throws {
        guard Set(value.keys) == expected else { throw Failure.fields }
    }

    static func text(_ value: ScenarioPayload?) throws -> String {
        guard case let .scalar(.text(value)) = value else { throw Failure.type }; return value
    }

    static func uint(_ value: ScenarioPayload?, positive: Bool = false) throws -> UInt64 {
        let text = try text(value)
        guard let number = UInt64(text), String(number).utf8.elementsEqual(text.utf8), !positive || number > 0 else { throw Failure.decimal }
        return number
    }

    static func integer(_ value: ScenarioPayload?, positive: Bool = false) throws -> Int {
        guard let number = try Int(exactly: uint(value, positive: positive)) else { throw Failure.decimal }; return number
    }

    static func base64(_ value: ScenarioPayload?) throws -> Data {
        let text = try text(value)
        guard let data = Data(base64Encoded: text), data.base64EncodedString().utf8.elementsEqual(text.utf8) else { throw Failure.type }; return data
    }

    static func array(_ value: ScenarioPayload?) throws -> [ScenarioPayload] {
        guard case let .array(value) = value else { throw Failure.type }; return value
    }
}

struct FeedbackLineage: Equatable {
    let node: Int
    let parent: Int?
}

struct FeedbackCatalogDocument {
    enum Event { case raw(Data), scheduler(FeedbackSchedulerRecord) }
    var catalog: FeedbackTraceCatalog
    let events: [Event]
    let records: [FeedbackSchedulerRecord]
    let lineage: [FeedbackLineage]
    static func read(_ url: URL) throws -> FeedbackCatalogDocument {
        let lines = try FeedbackCatalogLines(url)
        guard let first = try lines.next() else { throw FeedbackStrictJSON.Failure.header }
        let header = try FeedbackStrictJSON.object(first)
        try FeedbackStrictJSON.fields(header, ["kind", "schema", "nodes", "records", "scheduler_records", "lineage"])
        guard try FeedbackStrictJSON.text(header["kind"]) == "catalog-header", try FeedbackStrictJSON.text(header["schema"]) == "2" else { throw FeedbackStrictJSON.Failure.header }
        let nodeCount = try FeedbackStrictJSON.integer(header["nodes"]), recordCount = try FeedbackStrictJSON.integer(header["records"])
        let schedulerCount = try FeedbackStrictJSON.integer(header["scheduler_records"])
        let lineage = try FeedbackStrictJSON.array(header["lineage"]).map { value -> FeedbackLineage in
            let pair = try FeedbackStrictJSON.array(value); guard pair.count == 2 else { throw FeedbackStrictJSON.Failure.type }
            let node = try FeedbackStrictJSON.integer(pair[0], positive: true)
            let parent = pair[1] == .scalar(.null) ? nil : try FeedbackStrictJSON.integer(pair[1], positive: true)
            return .init(node: node, parent: parent)
        }
        guard lineage.count == schedulerCount else { throw FeedbackStrictJSON.Failure.coverage }
        try FeedbackBranchReplay.checkIdentity(lineage)
        var catalog = FeedbackTraceCatalog(); var events: [Event] = [], records: [FeedbackSchedulerRecord] = []
        while let line = try lines.next() {
            let value = try FeedbackStrictJSON.object(line), kind = try FeedbackStrictJSON.text(value["kind"])
            if catalog.nodes.count < nodeCount {
                guard kind == "catalog-node" else { throw FeedbackStrictJSON.Failure.coverage }
                try catalog.readDefinitionObject(value); continue
            }
            switch kind {
            case "scheduler-catalog":
                try FeedbackStrictJSON.fields(value, ["kind", "node", "predecessor", "input_ref", "step_ref"])
                let node = try FeedbackStrictJSON.integer(value["node"], positive: true)
                let parent = value["predecessor"] == .scalar(.null) ? nil : try FeedbackStrictJSON.integer(value["predecessor"], positive: true)
                guard records.count < lineage.count, lineage[records.count] == .init(node: node, parent: parent) else { throw FeedbackStrictJSON.Failure.identity }
                let input = try FeedbackStrictJSON.integer(value["input_ref"], positive: true), step = try FeedbackStrictJSON.integer(value["step_ref"], positive: true)
                guard input <= nodeCount, step <= nodeCount else { throw FeedbackStrictJSON.Failure.reference }
                let record = FeedbackSchedulerRecord(node: node, predecessor: parent, input: input, step: step)
                records.append(record); events.append(.scheduler(record))
            case "native-generated":
                try FeedbackStrictJSON.fields(value, ["kind", "owner", "scope", "messages", "cause_ordinal", "provenance", "generation_scopes"]); events.append(.raw(line))
            case "matched-native-receipt":
                try FeedbackStrictJSON.fields(value, ["kind", "plan", "candidate_ordinal", "native_cause_ordinal", "result"]); events.append(.raw(line))
            case "unmatched-native-receipt":
                try FeedbackStrictJSON.fields(value, ["kind", "owner", "plan", "result", "current_scope"]); events.append(.raw(line))
            default: throw FeedbackStrictJSON.Failure.fields
            }
            guard events.count <= recordCount, records.count <= schedulerCount else { throw FeedbackStrictJSON.Failure.coverage }
        }
        guard catalog.nodes.count == nodeCount, events.count == recordCount, records.count == schedulerCount else { throw FeedbackStrictJSON.Failure.coverage }
        return .init(catalog: catalog, events: events, records: records, lineage: lineage)
    }

    mutating func replay() throws -> (steps: Int, peakStates: Int) {
        try FeedbackBranchReplay.validate(records, catalog: &catalog, declared: lineage)
    }
}

final class FeedbackCatalogLines {
    private let file: FileHandle
    private var buffer = Data()
    init(_ url: URL) throws {
        file = try FileHandle(forReadingFrom: url)
    }

    deinit { try? file.close() }
    func next() throws -> Data? {
        while true {
            if let end = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<end]); buffer.removeSubrange(...end); return line
            }
            let bytes = try file.read(upToCount: 65536) ?? Data()
            if bytes.isEmpty {
                guard buffer.isEmpty else { throw FeedbackStrictJSON.Failure.invalidJSON }; return nil
            }
            buffer.append(bytes)
        }
    }
}
