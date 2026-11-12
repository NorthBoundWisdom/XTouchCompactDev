import CompactRemoteMIDI
import Foundation
import Testing

@Test func logArgumentIsLocalAndPreservesCommandParsers() throws {
    let options = try RemoteLoggingArguments(["--fader", "9", "--log", "/tmp/my log.jsonl", "--value", "41", "--channel", "2"])
    #expect(options.logPath == "/tmp/my log.jsonl")
    #expect(try FaderMoveCommand.parse(options.arguments).fader == 9)
    let client = try RemoteLoggingArguments(["--ssh", "host", "--log", "local.jsonl", "--listen-only"])
    let parsed = try RemoteClientOptions.parse(client.arguments)
    #expect(!parsed.sshArguments.contains("local.jsonl"))
    #expect(parsed.listenOnly)
    for arguments in [["--log"], ["--log", ""], ["--log", "--channel"], ["--log", "a", "--log", "b"], ["--log", "a\0b"]] {
        #expect(throws: RemoteMIDIError.self) { try RemoteLoggingArguments(arguments) }
    }
    #expect(try RemoteLoggingArguments(["--channel", "2"]).logPath == nil)
    // Every one-shot sender still uses its original validation after stripping --log.
    let button = try RemoteLoggingArguments(["--log", "b", "--button", "1", "--velocity", "2", "--channel", "2"])
    #expect(try ButtonLightCommand.parse(button.arguments).velocity == 2)
    for name in NonMotorFeedbackCommand.names {
        let fields: [String] = switch name {
        case "select-layer": ["--layer", "b"]
        case "ring-style": ["--encoder", "1", "--style", "4"]
        default: ["--encoder", "1", "--value", "28"]
        }
        let options = try RemoteLoggingArguments(fields + ["--channel", "2", "--log", "a"])
        _ = try NonMotorFeedbackCommand.parse(name, options.arguments)
    }
}

@Test func everyEventJSONLineHasObservationWallTimeAndCanonicalFraming() throws {
    let date = Date(timeIntervalSince1970: 123.456)
    for event in ["listening", "source-connected", "source-gone", "connect-failed", "midi", "stopped",
                  "fader-move-refused", "fader-move-sent", "sent-button-light", "sent-feedback"]
    {
        let data = try RemoteEventJSON.line(["event": event, "t": 1.25, "words": ["20B0013C"]], at: date)
        #expect(data.last == 10)
        #expect(data.filter { $0 == 10 }.count == 1)
        let row = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(row["wallClock"] as? String == "1970-01-01T00:02:03.456Z")
        #expect(row["event"] as? String == event)
        #expect(row["t"] as? Double == 1.25)
        #expect(row["words"] as? [String] == ["20B0013C"])
        #expect(try RemoteEventJSON.line(["event": event, "wallClock": "stale"], at: date)
            == RemoteEventJSON.line(["event": event], at: date))
    }
    for direction in ["device-to-client", "client-to-device", "app-to-bridge", "bridge-to-app"] {
        for delivery in ["sent", "forwarded", "failed", "dropped", "suppressed"] {
            let fields = RemoteEventJSON.forwarding(words: [0x20B0_017F], direction: direction, delivery: delivery)
            let data = try RemoteEventJSON.line(fields, at: date)
            let row = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(row["event"] as? String == "midi-forward")
            #expect(row["direction"] as? String == direction)
            #expect(row["delivery"] as? String == delivery)
            #expect(row["words"] as? [String] == ["20B0017F"])
        }
    }
}

@Test func postSendSummaryCountsOnlySelectedFaderTouchAndPositionOnBothLayers() throws {
    for fader in 1 ... 9 {
        let command = try FaderMoveCommand.parse(["--fader", String(fader), "--value", "40", "--channel", "2"])
        func cc(_ channel: UInt32, _ number: Int, _ value: UInt32) -> UInt32 {
            0x20B0_0000 | channel << 16 | UInt32(number) << 8 | value
        }
        let words = [cc(0, 100 + fader, 127), cc(4, 110 + fader, 0), cc(0, fader, 40), cc(5, 27 + fader, 41),
                     cc(0, 10, 1), 0x2090_007F, 0x40B0_017F]
        let summary = FaderObservationSummary(command: command, words: words)
        #expect(summary.touchMessages == 2)
        #expect(summary.positionMessages == 2)
        #expect(summary.fields["touchMessages"] as? Int == 2)
        #expect(summary.fields["positionMessages"] as? Int == 2)
        #expect(FaderObservationSummary(command: command, words: []).touchMessages == 0)
        #expect(FaderObservationSummary(command: command, words: []).positionMessages == 0)
    }
}
