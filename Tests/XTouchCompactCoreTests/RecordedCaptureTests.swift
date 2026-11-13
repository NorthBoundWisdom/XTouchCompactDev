import Foundation
import Testing
@testable import XTouchCompactCore

private var fixtureURL: URL {
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/CaptureReview/cases.json")
}

@Test func nativeCaptureAuditMatchesSharedPythonFixtures() throws {
    let fixtures = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [[String: Any]])
    for fixture in fixtures {
        let name = try #require(fixture["name"] as? String)
        let data = try Data(#require(fixture["jsonl"] as? String).utf8)
        let capture = try RecordedCapture(data: data)
        let audit = CaptureMotorAudit(capture: capture)
        let encoded = try JSONEncoder().encode(audit)
        let actual = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let expected = try #require(fixture["expected"] as? [String: Any])
        #expect(NSDictionary(dictionary: actual) == NSDictionary(dictionary: expected), "Native/Python parity: \(name)")
    }
}

@Test func captureParserRejectsMalformedSequenceTypesAndPartialLines() throws {
    let fixtures = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [[String: Any]])
    let valid = try #require(fixtures.first { $0["name"] as? String == "held-mismatch" }?["jsonl"] as? String)
    let invalid = [String(valid.dropLast()), valid + "{}\n", valid.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":true"),
                   valid.replacingOccurrences(of: "\"sequence\":1", with: "\"sequence\":2"),
                   valid.replacingOccurrences(of: "\"hardwareMode\":true", with: "\"hardwareMode\":1"),
                   valid.replacingOccurrences(of: "\"rawMIDI1Bytes\":[176,111,127]", with: "\"rawMIDI1Bytes\":[176,111]"),
                   valid.replacingOccurrences(of: "\"transmitChannel\":1", with: "\"transmitChannel\":0"),
                   valid.replacingOccurrences(of: "\"connectedInput\":{\"id\":1}", with: "\"connectedInput\":{\"id\":0}")]
    for text in invalid {
        #expect(throws: CaptureDocumentError.self) { try RecordedCapture(data: Data(text.utf8)) }
    }
    #expect(throws: CaptureDocumentError.tooLarge) { try RecordedCapture(data: Data(valid.utf8), byteLimit: 1) }
    #expect(throws: CaptureDocumentError.tooManyEvents) { try RecordedCapture(data: Data(valid.utf8), eventLimit: 1) }
}

@Test func captureCodecPreservesRawAddressSpacesAndUnknownProfileFacts() throws {
    let fixtures = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [[String: Any]])
    let text = try #require(fixtures.first { $0["name"] as? String == "held-mismatch" }?["jsonl"] as? String)
    let capture = try RecordedCapture(data: Data(text.utf8))
    #expect(capture.events[0].message == .controlChange(channel: 0, number: 111, value: 127))
    #expect(capture.events[0].decodedInput?.control == .faderTouch(1))
    #expect(capture.events[0].decodedInput?.layer == .b)
    #expect(capture.events[1].message == .controlChange(channel: 1, number: 1, value: 60))
    #expect(capture.session.transmitChannel == 1 && capture.session.receiveChannel == 2)
    let unknown = text.replacingOccurrences(of: "\"configuredGlobalReceiveChannel\":2", with: "\"configuredGlobalReceiveChannel\":null")
        .replacingOccurrences(of: "\"ledProtocol\":\"observed114\"", with: "\"ledProtocol\":null")
    let parsed = try RecordedCapture(data: Data(unknown.utf8))
    #expect(parsed.session.receiveChannel == nil && parsed.session.lightProtocol == nil)
}

@Test func canonicalCaptureVoiceFamiliesAndMetadataValidation() throws {
    let fixtures = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [[String: Any]])
    let text = try #require(fixtures.first { $0["name"] as? String == "held-mismatch" }?["jsonl"] as? String)
    let source = try text.split(separator: "\n").map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
    func encoded(_ rows: [[String: Any]]) throws -> Data {
        try rows.reduce(into: Data()) { data, row in try data.append(JSONSerialization.data(withJSONObject: row)); data.append(10) }
    }
    let messages: [([UInt8], MIDIMessage?)] = [
        ([0x90, 16, 127], .noteOn(channel: 0, number: 16, velocity: 127)),
        ([0x90, 16, 0], .noteOn(channel: 0, number: 16, velocity: 0)),
        ([0x80, 16, 0], .noteOff(channel: 0, number: 16, velocity: 0)),
        ([0xC0, 1], .programChange(channel: 0, number: 1)),
        ([0xE0, 127, 127], .pitchBend(channel: 0, value: 16383)),
        ([0xA0, 16, 70], nil), ([0xD0, 60], nil),
    ]
    for (raw, message) in messages {
        var rows = source; rows[1]["rawMIDI1Bytes"] = raw
        let capture = try RecordedCapture(data: encoded(rows))
        #expect(capture.events[0].message == message)
        #expect(capture.events[0].rawMIDI1Bytes == raw)
    }
    for mutation in 0 ... 5 {
        var rows = source
        switch mutation {
        case 0: rows[1].removeValue(forKey: "ignored")
        case 1: rows[1]["source"] = "unknown"
        case 2: rows[1]["delivery"] = "sent"
        case 3: rows[1]["rawMIDI1Bytes"] = [176, 101, 128]
        case 4: rows[1]["connection"] = ["generation": 0]
        default: rows[1]["rawMIDI1Bytes"] = NSNull()
        }
        #expect(throws: CaptureDocumentError.self) { try RecordedCapture(data: encoded(rows)) }
    }
}
