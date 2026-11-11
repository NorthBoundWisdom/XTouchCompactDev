#if os(macOS)
    import CryptoKit
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @Test @MainActor func reviewExportFingerprintsLiveAndCompletedCaptureWithoutSendingMIDI() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect(); model.beginHardwareObservation()
        let source = root.appendingPathComponent("source.jsonl")
        model.startCapture(source)
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127),
                          .controlChange(channel: 0, number: 1, value: 0),
                          .controlChange(channel: 0, number: 1, value: 127),
                          .controlChange(channel: 0, number: 101, value: 0)])
        let url = root.appendingPathComponent("review.json")
        model.exportInputReview(url)
        let receipt = try #require(model.lastReviewExport)
        #expect(receipt.captureSnapshotPath != nil)
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(receipt.sha256 == hash)
        #expect(try String(contentsOf: url.appendingPathExtension("sha256"), encoding: .utf8).hasPrefix(hash))
        #expect(try Data(contentsOf: root.appendingPathComponent("review.capture.jsonl")) == Data(contentsOf: source))
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((json["capture"] as? [String: Any])?["complete"] as? Bool == false)
        let header = try #require(try JSONSerialization.jsonObject(with: Data(Data(contentsOf: source).prefix { $0 != 10 })) as? [String: Any])
        #expect((json["capture"] as? [String: Any])?["sessionID"] as? String == (header["session"] as? [String: Any])?["sessionID"] as? String)
        #expect((json["currentContext"] as? [String: Any])?["contextID"] as? String != nil)
        #expect(json["hardwareAcceptance"] is NSNull)
        #expect(model.panelSnapshot.hardwareObservation?.reviewLayers.first?.coveredCount == 2)
        model.stopCapture()
        let completed = root.appendingPathComponent("completed.json")
        model.exportInputReview(completed)
        let completeJSON = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: completed)) as? [String: Any])
        #expect((completeJSON["capture"] as? [String: Any])?["complete"] as? Bool == true)
        #expect(midi.sent.isEmpty)
        #expect(model.error == nil)
    }

    @Test @MainActor func reviewExportPreservesExistingEvidenceAndRejectsCorruption() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ConsoleModel(startsMIDI: false)
        let report = root.appendingPathComponent("report.json")
        try Data("keep".utf8).write(to: report)
        model.exportInputReview(report)
        #expect(model.lastReviewExport == nil)
        #expect(try String(contentsOf: report, encoding: .utf8) == "keep")
        let capture = root.appendingPathComponent("broken.jsonl")
        model.startCapture(capture); model.stopCapture()
        try Data("broken".utf8).write(to: capture)
        let destination = root.appendingPathComponent("broken-review.json")
        model.exportInputReview(destination)
        #expect(model.error != nil && model.lastReviewExport == nil)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
        #expect(try String(contentsOf: capture, encoding: .utf8) == "broken")
    }

    @Test @MainActor func reviewResetDoesNotFabricatePairsOrClearSafetyTouches() throws {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect(); model.beginHardwareObservation()
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127)])
        model.resetHardwareObservation()
        #expect(model.session.state.isTouched(1))
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 0)])
        let row = try #require(model.panelSnapshot.hardwareObservation?.reviewLayers.first?.rows.first { $0.control == .faderTouch(1) })
        #expect(row.review.unmatchedReleaseCount == 1)
        #expect(!row.hasInputCoverage)
        #expect(!model.session.state.isTouched(1))
        #expect(midi.sent.isEmpty)
    }

    @Test @MainActor func captureRecordsLateConnectionAndInputSwitchDoesNotMixCoverage() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        model.beginHardwareObservation()
        let url = root.appendingPathComponent("connection.jsonl")
        model.startCapture(url) // A real app's initial connection callback can arrive later.
        midi.connect()
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127)])
        #expect(model.hardwareObserver.messageCount == 1)
        midi.onConnection?(CompactMIDIConnection())
        let second = CompactMIDIEndpoint(id: 2, name: "Second test input")
        midi.onConnection?(CompactMIDIConnection(connectedInput: second, connectedOutput: second))
        #expect(model.hardwareObserver.messageCount == 0)
        #expect(model.session.state.isTouched(1))
        model.stopCapture()
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let identities = rows.compactMap { row -> Int? in
            let connection = row["connection"] as? [String: Any]
            return (connection?["connectedInput"] as? [String: Any])?["id"] as? Int
        }
        #expect(identities == [1, 2])
        #expect(rows.last?["kind"] as? String == "capture-end")
        #expect(midi.sent.isEmpty)
    }

    @Test @MainActor func reportWithoutRecordingExplicitlyHasNoRawEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect(); model.beginHardwareObservation()
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127)])
        let url = root.appendingPathComponent("counts-only.json")
        model.exportInputReview(url)
        let receipt = try #require(model.lastReviewExport)
        #expect(receipt.captureSnapshotPath == nil)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(json["capture"] is NSNull)
        #expect(json["hardwareAcceptance"] is NSNull)
        #expect(!FileManager.default.fileExists(atPath: url.deletingPathExtension().appendingPathExtension("capture.jsonl").path))
        #expect(midi.sent.isEmpty)
    }

    @Test @MainActor func changingAppliedTXStartsNewCoverageButPreservesTouchOwnership() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect(); model.beginHardwareObservation()
        midi.onMessages?([.controlChange(channel: 0, number: 1, value: 0),
                          .controlChange(channel: 0, number: 101, value: 127)])
        model.transmitChannel = 2; model.configure()
        #expect(model.hardwareObserver.messageCount == 0)
        #expect(model.session.state.isTouched(1))
        midi.onMessages?([.controlChange(channel: 1, number: 1, value: 127)])
        #expect(model.hardwareObserver.reviews[.a]?[.fader(1)]?.minimum == 127)
        #expect(model.hardwareObserver.reviews[.a]?[.fader(1)]?.maximum == 127)
        #expect(midi.sent.isEmpty)
    }
#endif
