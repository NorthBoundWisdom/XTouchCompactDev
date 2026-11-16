#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    private var interchangeFixtures: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Capture")
    }

    @Test func currentRecorderMatchesFrozenMockInterchangeSample() throws {
        let sink = ControlledEvidenceWriter()
        var metadata = CaptureSessionMetadata()
        metadata.sessionID = "00000000-0000-4000-8000-000000000010"
        metadata.applicationVersion = "fixture-v1"
        metadata.configuredTX = 1; metadata.configuredGlobalRX = 2
        metadata.ledProtocol = "manual"; metadata.hardwareMode = false
        metadata.listenOnly = false; metadata.connectionGeneration = 0
        let capture = try MonitorCapture(url: URL(fileURLWithPath: "/unused-memory-capture"),
                                         started: Date(timeIntervalSince1970: 100), metadata: metadata, writerFactory: { _ in sink })
        let map = try FactoryStandardMap(transmitChannel: 0, globalReceiveChannel: 1)
        let events: [(MIDIMessage, CompactControl, Bool)] = [
            (.controlChange(channel: 0, number: 101, value: 127), .faderTouch(1), false),
            (.controlChange(channel: 0, number: 1, value: 32), .fader(1), false),
            (.controlChange(channel: 0, number: 1, value: 64), .fader(1), false),
            (.controlChange(channel: 0, number: 101, value: 0), .faderTouch(1), false),
            (.controlChange(channel: 0, number: 10, value: 48), .encoder(1), false),
            (.noteOn(channel: 0, number: 0, velocity: 127), .encoderPush(1), false),
            (.noteOff(channel: 0, number: 0, velocity: 0), .encoderPush(1), false),
            (.noteOn(channel: 0, number: 24, velocity: 127), .button(9), false),
            (.noteOff(channel: 0, number: 24, velocity: 0), .button(9), false),
            (.controlChange(channel: 0, number: 102, value: 127), .faderTouch(2), false),
            (.controlChange(channel: 0, number: 2, value: 88), .fader(2), false),
            (.controlChange(channel: 0, number: 102, value: 0), .faderTouch(2), false),
            (.noteOn(channel: 1, number: 8, velocity: 1), .button(9), true),
            (.controlChange(channel: 1, number: 26, value: 7), .encoder(1), true),
        ]
        for (offset, item) in events.enumerated() {
            let event = MonitorEvent(timestamp: Date(timeIntervalSince1970: 100 + Double(offset + 1) / 4),
                                     direction: item.2 ? .output : .input, source: .mock, message: item.0,
                                     control: item.1, hostLayer: .a, delivery: item.2 ? .sent : .received,
                                     ignored: false, text: .init("Synthetic fixture"))
            try capture.append(event, map: map, lightProtocol: .manual, hardwareMode: false, listenOnly: false)
        }
        try capture.finish(at: Date(timeIntervalSince1970: 104))
        if let path = ProcessInfo.processInfo.environment["XTOUCH_CAPTURE_SAMPLE_OUTPUT"] {
            try sink.bytes.write(to: URL(fileURLWithPath: path))
        }
        #expect(sink.closed)
        #expect(try sink.bytes == Data(contentsOf: interchangeFixtures.appendingPathComponent("xtouch-sample.jsonl")))
    }

    @Test @MainActor func foreignCaptureImportsCommonEvidenceButCannotReplayOrChangeLiveState() throws {
        let data = try Data(contentsOf: interchangeFixtures.appendingPathComponent("bcr-sample.jsonl"))
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(); model.setConsoleMode(.hardwareSend)
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127)])
        let before = model.panelSnapshot
        midi.sent.removeAll()
        let attempts = midi.sendAttempts
        model.importOfflineCapture(data: data, name: "bcr-sample.jsonl")
        let state = try #require(model.panelSnapshot.offlineCapture)
        #expect(state.failure == nil && state.deviceModel == "BCR2000")
        #expect(state.isComplete == true && state.eventCount == state.commonEvents.count)
        #expect(state.audit?.assessment == .notApplicable && state.audit?.evidenceSufficient == false)
        #expect(state.replay == nil && state.replayUnavailableReason?.arguments == ["BCR2000"])
        #expect(!state.commonEvents.isEmpty && state.commonEvents[0].source == "mock")
        let intents = model.panelIntents
        intents.stepOfflineReplay?(); intents.runOfflineReplay?(); intents.resetOfflineReplay?(); intents.setOfflineReplayFader?(1, 100)
        #expect(model.panelSnapshot.offlineCapture?.replay == nil)
        var after = model.panelSnapshot; after.offlineCapture = before.offlineCapture
        #expect(after == before && midi.sent.isEmpty && midi.sendAttempts == attempts)
    }
#endif
