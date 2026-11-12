#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    final class ControlledEvidenceWriter: EvidenceWriting {
        var bytes = Data()
        var writes = 0
        var failWrite: Int?
        var failFlush = false
        var closed = false
        func write(_ data: Data) throws {
            writes += 1
            if writes == failWrite {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            bytes.append(data)
        }

        func synchronize() throws {
            if failFlush {
                throw CocoaError(.fileWriteOutOfSpace)
            }
        }

        func close() throws {
            closed = true
        }

        var rows: [[String: Any]] {
            get throws {
                try String(decoding: bytes, as: UTF8.self).split(separator: "\n").map {
                    try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
                }
            }
        }
    }

    @Test @MainActor func evidenceRefusesExistingFilesAndLinksWithoutChangingOriginals() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("evidence.jsonl")
        let data = Data("preserved evidence".utf8)
        try data.write(to: original)
        let model = ConsoleModel(startsMIDI: false)
        model.startCapture(original)
        #expect(model.error is EvidenceError)
        #expect(model.capturePath == nil)
        #expect(try Data(contentsOf: original) == data)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        #expect(throws: EvidenceError.self) { try ExclusiveEvidenceFile(url: link) }
        #expect(try Data(contentsOf: original) == data)
        let fresh = root.appendingPathComponent("new.jsonl")
        let writer = try ExclusiveEvidenceFile(url: fresh)
        #expect(throws: EvidenceError.self) { try ExclusiveEvidenceFile(url: fresh) }
        try writer.write(Data("new".utf8)); try writer.close()
        #expect(try String(contentsOf: fresh, encoding: .utf8) == "new")
    }

    @Test @MainActor func captureMetadataSeparatesConfiguredChannelsFromUnknownHardwareFacts() throws {
        let midi = FakeMIDIService()
        let writer = ControlledEvidenceWriter()
        let model = ConsoleModel(startsMIDI: false, midi: midi, evidenceWriterFactory: { _ in writer })
        model.transmitChannel = 3; model.feedbackChannel = 9; model.configure()
        midi.connect(); model.beginHardwareObservation()
        model.startCapture(URL(fileURLWithPath: "/unused-injected-capture"))
        model.stopCapture()
        let rows = try writer.rows
        let session = try #require(rows.first?["session"] as? [String: Any])
        #expect(session["configuredTransmitChannel"] as? Int == 3)
        #expect(session["configuredGlobalReceiveChannel"] as? Int == 9)
        #expect(session["actualGlobalReceiveChannel"] is NSNull)
        #expect(session["firmwareVersion"] is NSNull)
        #expect(session["selectedInputID"] is NSNull)
        #expect((session["connectedInput"] as? [String: Any])?["id"] as? Int == 1)
        #expect(session["listenOnly"] as? Bool == true)
        #expect(rows.filter { $0["kind"] as? String == "capture-end" }.count == 1)
        #expect(writer.closed)
        #expect(midi.sent.isEmpty)
    }

    @Test @MainActor func failedCaptureWriteClosesRecordingAndSurfacesErrorWithoutEndMarker() throws {
        let midi = FakeMIDIService()
        let writer = ControlledEvidenceWriter(); writer.failWrite = 2
        let model = ConsoleModel(startsMIDI: false, midi: midi, evidenceWriterFactory: { _ in writer })
        midi.connect(); model.beginHardwareObservation()
        model.startCapture(URL(fileURLWithPath: "/unused-injected-capture"))
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127)])
        #expect(model.error != nil)
        #expect(model.capturePath == nil)
        #expect(writer.closed)
        model.stopCapture()
        #expect(try !writer.rows.contains { $0["kind"] as? String == "capture-end" })
        #expect(model.panelSnapshot.fader(1)?.isTouched == true) // Observation still works.
        #expect(midi.sent.isEmpty)
    }

    @Test func failedCaptureFlushNeverAddsACompletionMarkerOnRetry() throws {
        let writer = ControlledEvidenceWriter()
        let capture = try MonitorCapture(url: URL(fileURLWithPath: "/unused"), started: Date(timeIntervalSince1970: 123), writerFactory: { _ in writer })
        writer.failFlush = true
        #expect(throws: CocoaError.self) { try capture.finish(at: Date(timeIntervalSince1970: 124)) }
        writer.failFlush = false
        try capture.finish(at: Date(timeIntervalSince1970: 125))
        #expect(try writer.rows.count == 1)
        #expect(writer.closed)
    }

    @Test func captureRecordsKnownBuildRevisionAndDirtyStateWithoutClaimingDeviceFirmware() throws {
        let writer = ControlledEvidenceWriter()
        let metadata = CaptureSessionMetadata(applicationVersion: "0.1.0", sourceRevision: String(repeating: "a", count: 40), sourceTreeDirty: true)
        let capture = try MonitorCapture(url: URL(fileURLWithPath: "/unused"), started: Date(timeIntervalSince1970: 123), metadata: metadata, writerFactory: { _ in writer })
        try capture.finish(at: Date(timeIntervalSince1970: 124))
        let session = try #require(writer.rows.first?["session"] as? [String: Any])
        #expect(session["sourceRevision"] as? String == String(repeating: "a", count: 40))
        #expect(session["sourceTreeDirty"] as? Bool == true)
        #expect(session["firmwareVersion"] is NSNull)
    }
#endif
#if os(macOS)
    @Test func captureMetadataRecordsRemoteHardwareRouteSeparatelyFromUSB() {
        let remote = CompactMIDIEndpoint(id: 7, name: "X-TOUCH COMPACT (via henrys-mac-mini)")
        let local = CompactMIDIEndpoint(id: 8, name: "X-TOUCH COMPACT")
        var metadata = CaptureSessionMetadata(connectedInput: remote, connectedOutput: remote)
        #expect(metadata.json["route"] as? String == "remote")
        #expect(metadata.json["remoteBridgeHost"] as? String == "henrys-mac-mini")
        metadata.connectedInput = local; metadata.connectedOutput = local
        #expect(metadata.json["route"] as? String == "local")
        #expect(metadata.json["remoteBridgeHost"] is NSNull)
        metadata.connectedInput = nil; metadata.connectedOutput = nil
        #expect(metadata.json["route"] is NSNull)
        let connection = CompactMIDIConnection(connectedInput: local, connectedOutput: remote)
        #expect(connection.remoteBridgeHost == "henrys-mac-mini")
        #expect(local.remoteBridgeHost == nil)
    }
#endif
