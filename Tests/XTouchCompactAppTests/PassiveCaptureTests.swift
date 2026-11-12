#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @Test @MainActor func hardwareListeningBlocksEverySendPathAndDoesNotReplayOnExit() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        #expect(model.panelSnapshot.listenOnly)
        midi.connect(); model.useHardware(true)
        #expect(midi.sent.isEmpty) // No connection Program Change or LED sync.
        model.recallMotors(); model.setLayer(.b); model.realignCurrentLayer()
        model.configure(); model.applyConfiguration(.neutral)
        model.encoderChanged(1, value: 64); model.pressButton(1); model.agentPrimary(1)
        midi.onMessages?([.controlChange(channel: 0, number: 111, value: 127)])
        model.setParameter("b.Fader.1", value: 80, fromAgent: true)
        #expect(!model.session.state.isMotorPending(1))
        midi.onConnection?(CompactMIDIConnection()); midi.connect()
        #expect(midi.sent.isEmpty)
        #expect(model.events.contains { $0.delivery == .suppressed })
        #expect(model.session.state.isTouched(1))
        model.setListenOnly(false)
        #expect(midi.sent.isEmpty) // Enabling output itself is silent.
        midi.onMessages?([.controlChange(channel: 0, number: 111, value: 0)])
        #expect(!midi.sent.contains {
            if case .controlChange(_, 1, _) = $0 {
                return true
            }; return false
        })
        model.faderChanged(1, value: 91) // Fresh explicit write is required.
        #expect(midi.sent.contains(.controlChange(channel: 0, number: 1, value: 91)))
        model.setListenOnly(true)
        midi.sent.removeAll()
        model.faderChanged(1, value: 92)
        #expect(midi.sent.isEmpty)
    }

    @Test @MainActor func passiveTransitionPreservesLayerEvidenceAndPhysicalTouch() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect(); model.useHardware(true)
        midi.onMessages?([.controlChange(channel: 0, number: 111, value: 127)])
        #expect(model.session.state.layerMismatch)
        model.setListenOnly(false)
        #expect(model.session.state.layerMismatch)
        #expect(model.session.state.isTouched(1))
        #expect(midi.sent.isEmpty)
        model.realignCurrentLayer()
        #expect(midi.sent.isEmpty)
        #expect(model.session.state.isTouched(1))
        #expect(model.session.state.layerMismatch)
        midi.onMessages?([.controlChange(channel: 0, number: 111, value: 0)])
        #expect(midi.sent.isEmpty)
        model.realignCurrentLayer()
        #expect(midi.sent.contains(.programChange(channel: 0, number: 0)))
    }

    @Test @MainActor func failedLayerAssertionPreservesMismatchAndBlocksFreshMotors() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(); model.setConsoleMode(.hardwareSend)
        midi.onMessages?([.controlChange(channel: 0, number: 37, value: 41)])
        midi.fails = true
        model.realignCurrentLayer()
        #expect(model.session.state.observedLayer == .b)
        #expect(model.session.state.layerMismatch)
        #expect(model.panelSnapshot.hardwareFeedbackNeedsSync == true)
        midi.fails = false
        model.faderChanged(1, value: 99)
        #expect(midi.sent.isEmpty)
        model.realignCurrentLayer()
        #expect(model.session.state.observedLayer == nil)
        #expect(model.panelSnapshot.hardwareFeedbackNeedsSync == false)
        midi.sent.removeAll()
        model.faderChanged(1, value: 99)
        #expect(midi.sent == [.controlChange(channel: 0, number: 1, value: 99)])
    }

    @Test @MainActor func passiveLayerSelectionCannotEraseMismatchBeforeWriteback() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(); model.setConsoleMode(.hardwareListen)
        midi.onMessages?([.controlChange(channel: 0, number: 37, value: 41)])
        #expect(model.session.state.observedLayer == .b)
        model.realignCurrentLayer() // Listening: no physical layer assertion was sent.
        #expect(midi.sent.isEmpty)
        #expect(model.session.state.observedLayer == .b)
        #expect(model.session.state.layerMismatch)
        model.setConsoleMode(.hardwareSend)
        model.faderChanged(1, value: 99)
        #expect(midi.sent.isEmpty)
        model.realignCurrentLayer() // Explicit assertion after enabling writes.
        #expect(midi.sent.first == .programChange(channel: 0, number: 0))
        #expect(model.session.state.observedLayer == nil)
        midi.sent.removeAll()
        model.faderChanged(1, value: 99)
        #expect(midi.sent == [.controlChange(channel: 0, number: 1, value: 99)])
    }

    @Test @MainActor func captureRetainsAllInputsBeyondMonitorLimitWithRawBytesAndLayerEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("capture.jsonl")
        let midi = FakeMIDIService()
        let date = Date(timeIntervalSince1970: 123)
        let model = ConsoleModel(startsMIDI: false, midi: midi, now: { date })
        midi.connect(); model.useHardware(true)
        model.startCapture(url)
        #expect(model.panelSnapshot.capturePath == url.path)
        for index in 0 ..< 260 {
            midi.onMessages?([.controlChange(channel: 0, number: 37, value: UInt8(index % 128))])
            if index == 130 {
                model.clearMonitor()
            } // Clearing UI must not truncate the capture.
        }
        model.stopCapture(); model.stopCapture()
        #expect(model.panelSnapshot.capturePath == nil)
        #expect(model.events.count <= 120)
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(rows.first?["kind"] as? String == "capture-start")
        #expect(rows.last?["kind"] as? String == "capture-end")
        let inputs = rows.filter { $0["direction"] as? String == "IN" }
        #expect(inputs.count == 260)
        #expect(inputs.first?["rawMIDI1Bytes"] as? [Int] == [0xB0, 37, 0])
        #expect(inputs.first?["hostLayer"] as? String == "a")
        #expect(inputs.first?["deviceLayer"] as? String == "b")
        #expect(inputs.first?["control"] as? String == "Encoder 1")
        #expect((inputs.first?["decoded"] as? [String: Any])?["value"] as? Int == 0)
        #expect(inputs.first?["listenOnly"] as? Bool == true)
        #expect(inputs.first?["transmitChannel"] as? Int == 1)
        #expect(inputs.first?["globalReceiveChannel"] as? Int == 1)
        #expect(rows.last?["eventCount"] as? Int == rows.count - 2)
        #expect(midi.sent.isEmpty)
    }

    @Test @MainActor func captureFailureIsVisibleAndSymlinkOriginalIsPreserved() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("original")
        try Data("keep".utf8).write(to: original)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
        let model = ConsoleModel(startsMIDI: false)
        model.startCapture(link)
        #expect(model.error != nil)
        #expect(model.capturePath == nil)
        #expect(try String(contentsOf: original, encoding: .utf8) == "keep")
        model.startCapture(root) // Directory is not a writable capture file.
        #expect(model.error != nil)
        #expect(model.capturePath == nil)
    }
#endif
#if os(macOS)
    @Test @MainActor func captureDistinguishesSentSuppressedFailedAndUnknownInput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("delivery.jsonl")
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect(); model.useHardware(true); model.startCapture(url)
        model.faderChanged(1, value: 30) // suppressed
        model.setListenOnly(false)
        model.faderChanged(1, value: 40) // sent, not physically observed
        #expect(model.panelSnapshot.fader(1)?.observed == nil)
        midi.fails = true
        model.faderChanged(1, value: 50) // failed
        midi.onMessages?([.noteOff(channel: 5, number: 3, velocity: 9),
                          .programChange(channel: 5, number: 2), .pitchBend(channel: 5, value: 8193)])
        model.stopCapture()
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(Set(rows.compactMap { $0["delivery"] as? String }) == ["suppressed", "sent", "failed", "received"])
        let note = try #require(rows.first { $0["rawMIDI1Bytes"] as? [Int] == [0x85, 3, 9] })
        #expect(note["ignored"] as? Bool == true)
        #expect(note["decoded"] == nil)
        #expect(rows.contains { $0["rawMIDI1Bytes"] as? [Int] == [0xC5, 2] })
        #expect(rows.contains { $0["rawMIDI1Bytes"] as? [Int] == [0xE5, 1, 64] })
    }
#endif
