import Foundation
import Testing
@testable import XTouchCompactCore

private var captureFixtures: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Capture")
}

@Test func frozenCompactSampleKeepsCommonFieldsCountsAndNativeReplay() throws {
    let data = try Data(contentsOf: captureFixtures.appendingPathComponent("xtouch-sample.jsonl"))
    let common = try CaptureCommonDocument(data: data)
    #expect(common.deviceModel == "X-TOUCH COMPACT" && !common.isForeignDevice)
    #expect(common.integrity.eventCount == 14 && common.integrity.isComplete)
    #expect(common.events.first?.sequence == 1 && common.events.last?.sequence == 14)
    #expect(common.events.first?.source == "mock" && common.events.first?.direction == "IN")
    #expect(common.events.first?.rawMIDI1Bytes == [176, 101, 127])
    #expect(common.events.first?.timestamp == "1970-01-01T00:01:40.250Z")
    #expect(common.events.last?.direction == "OUT")
    var replay = try RecordedCaptureReplay(inspection: common)
    while try replay.step() {}
    #expect(replay.inputsReplayed == 12 && replay.recordedOutputsSkipped == 2)
    #expect(replay.session.state.map.globalReceiveChannel == 1)
}

@Test func foreignSamplePreservesCommonFieldsAndExplicitlyRejectsReplayAndMotorPass() throws {
    let data = try Data(contentsOf: captureFixtures.appendingPathComponent("bcr-sample.jsonl"))
    let common = try CaptureCommonDocument(data: data)
    let provenance = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: captureFixtures.appendingPathComponent("provenance.json"))) as? [String: [String: Any]])
    let count = try #require(provenance["bcr-sample.jsonl"]?["eventCount"] as? Int)
    #expect(common.deviceModel == "BCR2000" && common.isForeignDevice)
    #expect(common.integrity.eventCount == count && common.events.count == count && common.integrity.isComplete)
    #expect(common.events.first?.source == "mock" && common.events.first?.timestamp != nil)
    #expect(common.events.first?.rawMIDI1Bytes != nil)
    #expect(throws: CaptureDeviceMismatch(deviceModel: "BCR2000")) { _ = try RecordedCaptureReplay(inspection: common) }
    do { try common.requireCompactDevice(); Issue.record("Foreign device accepted") }
    catch let error as CaptureDeviceMismatch { #expect(error.localizedDescription.contains("BCR2000")) }
    let audit = try CaptureMotorAudit(foreignCapture: common)
    #expect(audit.assessment == .notApplicable && !audit.evidenceSufficient)
    #expect(audit.eventCount == count && audit.complete)
    #expect(audit.assessment != .noRecordedViolations)
}

@Test func commonCaptureValidationPreservesPrefixAndRejectsBadSequenceAndTypes() throws {
    let data = try Data(contentsOf: captureFixtures.appendingPathComponent("xtouch-sample.jsonl"))
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
    let prefix = Data((lines.dropLast().joined(separator: "\n") + "\n").utf8)
    #expect(try !CaptureCommonDocument(data: prefix).integrity.isComplete)
    for (key, value) in [("sequence", "true"), ("sequence", "99"), ("source", "false"), ("rawMIDI1Bytes", "[999]")] {
        var rows = try lines.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        rows[1][key] = try JSONSerialization.jsonObject(with: Data(value.utf8), options: .fragmentsAllowed)
        var corrupted = Data()
        for row in rows {
            try corrupted.append(JSONSerialization.data(withJSONObject: row)); corrupted.append(10)
        }
        #expect(throws: (any Error).self) { _ = try CaptureCommonDocument(data: corrupted) }
    }
}
