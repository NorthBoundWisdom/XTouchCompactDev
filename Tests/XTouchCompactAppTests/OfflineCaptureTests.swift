#if os(macOS)
    import Darwin
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    private func offlineFixture(_ name: String = "held-mismatch") throws -> (Data, String) {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("Fixtures/CaptureReview/cases.json"))) as? [[String: Any]])
        let fixture = try #require(rows.first { $0["name"] as? String == name })
        return try (Data(#require(fixture["jsonl"] as? String).utf8), #require(fixture["sha256"] as? String))
    }

    @Test @MainActor func offlineImportAndClearCannotChangeLiveSessionOrTransmit() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, storageRoot: root, isolated: true)
        midi.connect(); model.setConsoleMode(.hardwareSend)
        midi.onMessages?([.controlChange(channel: 0, number: 111, value: 127)])
        model.faderChanged(1, value: 91)
        model.saveWorkspace()
        let file = ProtectedWorkspaceStore(directory: root).url
        let saved = try Data(contentsOf: file)
        let before = model.panelSnapshot
        let (data, hash) = try offlineFixture()
        #expect(model.panelIntents.openOfflineCapture != nil && model.panelIntents.clearOfflineCapture != nil)
        model.importOfflineCapture(data: data, name: "recording.jsonl")
        let offline = try #require(model.panelSnapshot.offlineCapture)
        #expect(offline.name == "recording.jsonl" && offline.sha256 == hash)
        #expect(offline.audit?.motorWhileTouched == [2])
        #expect(offline.audit?.motorDuringLayerMismatch == [2])
        var after = model.panelSnapshot; after.offlineCapture = before.offlineCapture
        #expect(after == before)
        #expect(midi.sent.isEmpty && midi.sendAttempts == 0)
        #expect(try Data(contentsOf: file) == saved)
        model.panelIntents.clearOfflineCapture?()
        #expect(model.panelSnapshot == before)
    }

    @Test @MainActor func failedOfflineImportKeepsPriorResultAndDoesNotBecomeRuntimeFailure() throws {
        let model = ConsoleModel(startsMIDI: false, midi: FakeMIDIService(), isolated: true)
        try model.importOfflineCapture(data: offlineFixture().0, name: "valid.jsonl")
        let original = model.panelSnapshot.offlineCapture
        model.importOfflineCapture(data: Data("bad\n".utf8), name: "invalid.jsonl")
        #expect(model.panelSnapshot.offlineCapture?.name == original?.name)
        #expect(model.panelSnapshot.offlineCapture?.sha256 == original?.sha256)
        #expect(model.panelSnapshot.offlineCapture?.failure != nil)
        #expect(model.error == nil)
    }

    @Test func offlineFileLoaderIsReadOnlyBoundedAndRejectsSpecialFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("original.jsonl")
        let (data, hash) = try offlineFixture()
        try data.write(to: file)
        let loaded = try OfflineCaptureLoader.load(file)
        #expect(loaded.sha256 == hash && loaded.byteCount == data.count)
        #expect(try Data(contentsOf: file) == data)
        let link = root.appendingPathComponent("link.jsonl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: POSIXError.self) { try OfflineCaptureLoader.load(link) }
        let fifo = root.appendingPathComponent("fifo.jsonl")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(throws: OfflineCaptureReadError.self) { try OfflineCaptureLoader.load(fifo) }
        let huge = root.appendingPathComponent("huge.jsonl")
        #expect(FileManager.default.createFile(atPath: huge.path, contents: Data()))
        let writer = try FileHandle(forWritingTo: huge)
        try writer.truncate(atOffset: UInt64(RecordedCapture.maximumBytes + 1)); try writer.close()
        #expect(throws: CaptureDocumentError.tooLarge) { try OfflineCaptureLoader.load(huge) }
        #expect(throws: OfflineCaptureReadError.self) { try OfflineCaptureLoader.load(#require(URL(string: "https://example.invalid/capture"))) }
    }

    @Test @MainActor func staleAsyncCaptureImportCannotReplaceNewerInputOrClear() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("old.jsonl")
        try offlineFixture().0.write(to: file)
        let model = ConsoleModel(startsMIDI: false, midi: FakeMIDIService(), isolated: true)
        model.loadOfflineCapture(file)
        let first = model.offlineImportTask
        try model.importOfflineCapture(data: offlineFixture("empty").0, name: "new.jsonl")
        await first?.value
        #expect(model.panelSnapshot.offlineCapture?.name == "new.jsonl")
        model.loadOfflineCapture(file)
        let second = model.offlineImportTask
        model.clearOfflineCapture()
        await second?.value
        #expect(model.panelSnapshot.offlineCapture?.name == nil)
        #expect(model.panelSnapshot.offlineCapture?.isLoading == false)
    }
#endif
