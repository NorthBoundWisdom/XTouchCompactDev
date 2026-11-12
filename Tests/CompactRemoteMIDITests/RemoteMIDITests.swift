@testable import CompactRemoteMIDI
import Foundation
import Testing

@Test func sshHostsAndRemotePathsRejectOptionAndShellInjection() throws {
    for good in ["henrys-mac-mini", "100.99.104.81", "henrykang@henrys-mac-mini", "fd7a:115c::1", "mini_2"] {
        #expect(try validatedRemoteHost(good) == good)
    }
    for bad in ["", "-oProxyCommand=x", "host name", "a;b", "$(id)", "a`b`", ".hidden", "@host", "a@b@c", "h'x"] {
        #expect(throws: RemoteMIDIError.self) { _ = try validatedRemoteHost(bad) }
    }
    for good in [".xtouch-remote/XTouchRemoteMIDI", "/Users/x/bin/XTouchRemoteMIDI"] {
        #expect(try validatedRemotePath(good) == good)
    }
    for bad in ["", "-x", "a b", "a;b", "../x", "a/../b", "dir/", "~/x", "$HOME/x"] {
        #expect(throws: RemoteMIDIError.self) { _ = try validatedRemotePath(bad) }
    }
}

@Test func clientBuildsBatchModeSSHCommandAndRemoteEndpointNames() throws {
    let options = try RemoteClientOptions.parse(["--ssh", "henrykang@henrys-mac-mini"])
    #expect(options.label == "henrys-mac-mini")
    #expect(options.endpointName == "X-TOUCH COMPACT (via henrys-mac-mini)")
    #expect(options.endpointName.uppercased().contains("X-TOUCH COMPACT")) // App auto-match still applies.
    let arguments = options.sshArguments
    #expect(arguments.contains("BatchMode=yes"))
    // "--" ends ssh options, so the host can never be read as one.
    let separator = try #require(arguments.firstIndex(of: "--"))
    #expect(Array(arguments[(separator + 1)...]) == ["henrykang@henrys-mac-mini", ".xtouch-remote/XTouchRemoteMIDI",
                                                     "bridge", "--device", "'X-TOUCH COMPACT'"])
    let custom = try RemoteClientOptions.parse(["--ssh", "mini", "--label", "lab", "--remote-binary", "/opt/x/XTouchRemoteMIDI"])
    #expect(custom.endpointName == "X-TOUCH COMPACT (via lab)")
    #expect(custom.sshArguments.contains("/opt/x/XTouchRemoteMIDI"))
    #expect(throws: RemoteMIDIError.missingArgument("--ssh")) { _ = try RemoteClientOptions.parse([]) }
    #expect(throws: RemoteMIDIError.missingValue("--ssh")) { _ = try RemoteClientOptions.parse(["--ssh", "--label"]) }
    #expect(throws: RemoteMIDIError.unknownArgument("--x")) { _ = try RemoteClientOptions.parse(["--ssh", "h", "--x"]) }
    for device in ["X (via y)", "a'b", "line\nbreak", ""] {
        #expect(throws: RemoteMIDIError.self) { _ = try RemoteClientOptions.parse(["--ssh", "h", "--device", device]) }
    }
}

@Test func remoteEndpointNamesIdentifyTheBridgeAndHaveStableIDs() {
    #expect(RemoteMIDIDefaults.bridgeHost(fromEndpointName: "X-TOUCH COMPACT (via henrys-mac-mini)") == "henrys-mac-mini")
    #expect(RemoteMIDIDefaults.bridgeHost(fromEndpointName: "X-TOUCH COMPACT") == nil)
    #expect(RemoteMIDIDefaults.bridgeHost(fromEndpointName: "X-TOUCH COMPACT (via )") == nil)
    let source = RemoteMIDIDefaults.endpointUniqueID(host: "henrys-mac-mini", isSource: true)
    #expect(source == RemoteMIDIDefaults.endpointUniqueID(host: "HENRYS-MAC-MINI", isSource: true))
    #expect(source != RemoteMIDIDefaults.endpointUniqueID(host: "henrys-mac-mini", isSource: false))
    #expect(source > 0)
}

@Test func bridgeMatchesOnlyThePhysicalControllerNeverARemoteEndpoint() throws {
    let options = try RemoteBridgeOptions.parse(["--status", "/tmp/s.json"])
    #expect(options.statusPath == "/tmp/s.json")
    #expect(options.matchesDevice("X-TOUCH COMPACT"))
    #expect(options.matchesDevice("x-touch compact Port 1"))
    #expect(!options.matchesDevice("X-TOUCH COMPACT (via other-mac)"))
    #expect(!options.matchesDevice("X-TOUCH MINI"))
    #expect(throws: RemoteMIDIError.unknownArgument("--listen")) { _ = try RemoteBridgeOptions.parse(["--listen", "x"]) }
}

@Test func framesRoundTripAcrossArbitrarySplits() throws {
    let frames: [RemoteFrame] = [.hello(version: 1), .ping, .device(source: true, destination: false),
                                 .midi(words: [0x20B0_0164]), .midi(words: Array(repeating: 0x3016_F000, count: 64))]
    let bytes = frames.flatMap(\.encoded)
    #expect(RemoteFrame.midi(words: [0x2090_107F]).encoded == [2, 0, 4, 0x20, 0x90, 0x10, 0x7F])
    for chunk in [1, 2, 3, 7, bytes.count] {
        var decoder = RemoteFrameDecoder()
        var decoded: [RemoteFrame] = []
        for start in stride(from: 0, to: bytes.count, by: chunk) {
            decoded += try decoder.append(bytes[start ..< min(start + chunk, bytes.count)])
        }
        #expect(decoded == frames)
    }
}

@Test func malformedFramesAreFatalProtocolErrors() {
    let cases: [[UInt8]] = [
        [9, 0, 0], // Unknown kind.
        [2, 0, 0], // Empty MIDI.
        [2, 0, 3, 1, 2, 3], // Not whole words.
        [2, 1, 4], // Larger than 64 words.
        [1, 0, 5] + Array("XXXX".utf8) + [1], // Bad magic.
        [3, 0, 2, 2, 0], // Non-boolean device flag.
        [4, 0, 1, 0], // Ping with payload.
    ]
    for bytes in cases {
        var decoder = RemoteFrameDecoder()
        #expect(throws: RemoteMIDIError.self) { _ = try decoder.append(bytes) }
    }
}

@Test func bridgeStatusRoundTripsWithISODates() throws {
    let status = RemoteBridgeStatus(pid: 42, running: true, deviceSource: "X-TOUCH COMPACT",
                                    framesToClient: 3, updatedAt: Date(timeIntervalSince1970: 1_800_000_000))
    let data = try RemoteBridgeStatus.encoder.encode(status)
    #expect(String(decoding: data, as: UTF8.self).contains("\"updatedAt\" : \"2027-01-15T08:00:00Z\""))
    #expect(try RemoteBridgeStatus.decoder.decode(RemoteBridgeStatus.self, from: data) == status)
}

@Test func listenOnlyIsPassedToTheBridgeAndOffByDefault() throws {
    let normal = try RemoteClientOptions.parse(["--ssh", "mini"])
    #expect(!normal.listenOnly && !normal.sshArguments.contains("--listen-only"))
    let passive = try RemoteClientOptions.parse(["--listen-only", "--ssh", "mini"])
    #expect(passive.listenOnly)
    #expect(passive.sshArguments.last == "--listen-only")
    #expect(passive.endpointName == normal.endpointName) // Same port identity; only the direction changes.
    #expect(try RemoteBridgeOptions.parse(["--listen-only"]).listenOnly)
    #expect(try !RemoteBridgeOptions.parse([]).listenOnly)
}

@Test func buttonLightCommandCanOnlyExpressAButtonLEDNoteOn() throws {
    let command = try ButtonLightCommand.parse(["--button", "1", "--velocity", "2", "--channel", "1"])
    #expect(command.word == 0x2090_0002)
    #expect(try ButtonLightCommand.parse(["--button", "39", "--velocity", "3", "--channel", "16"]).word == 0x209F_2603)
    // Every expressible word is a Note On (status 0x9n) for notes 0…38 with velocity 0…3.
    for button in 1 ... 39 {
        for velocity in 0 ... 3 {
            for channel in [1, 7, 16] {
                let word = ButtonLightCommand(button: button, velocity: velocity, channel: channel).word
                #expect(word >> 28 == 0x2 && (word >> 20) & 0xF == 0x9)
                #expect((word >> 8) & 0xFF == UInt32(button - 1) && word & 0xFF == UInt32(velocity))
            }
        }
    }
    // The channel is never defaulted or inferred, and out-of-range values are refused.
    let invalid: [[String]] = [
        ["--button", "1", "--velocity", "1"], ["--button", "0", "--velocity", "1", "--channel", "1"],
        ["--button", "40", "--velocity", "1", "--channel", "1"], ["--button", "1", "--velocity", "4", "--channel", "1"],
        ["--button", "1", "--velocity", "127", "--channel", "1"], ["--button", "1", "--velocity", "1", "--channel", "0"],
        ["--button", "1", "--velocity", "1", "--channel", "17"], ["--button", "x", "--velocity", "1", "--channel", "1"],
        ["--button", "1", "--velocity", "1", "--channel", "1", "--cc", "1"],
    ]
    for arguments in invalid {
        #expect(throws: RemoteMIDIError.self) { _ = try ButtonLightCommand.parse(arguments) }
    }
}

@Test func nonMotorFeedbackCommandsNeverAddressAMotorOrTheModeSwitch() throws {
    #expect(try NonMotorFeedbackCommand.parse("ring-display", ["--encoder", "1", "--value", "27", "--channel", "2"]).word == 0x20B1_1A1B)
    #expect(try NonMotorFeedbackCommand.parse("ring-style", ["--encoder", "16", "--style", "4", "--channel", "2"]).word == 0x20B1_1904)
    #expect(try NonMotorFeedbackCommand.parse("select-layer", ["--layer", "b", "--channel", "2"]).word == 0x20C1_0100)
    #expect(try NonMotorFeedbackCommand.parse("select-layer", ["--channel", "1", "--layer", "a"]).word == 0x20C0_0000)
    // Enumerate everything expressible: Control Change numbers stay within 10…41.
    for channel in [1, 2, 16] {
        for encoder in 1 ... 16 {
            for value in 0 ... 28 {
                let word = NonMotorFeedbackCommand.ringDisplay(encoder: encoder, value: value, channel: channel).word
                #expect((word >> 20) & 0xF == 0xB && (26 ... 41).contains(Int((word >> 8) & 0x7F)))
            }
            for style in 0 ... 4 {
                let word = NonMotorFeedbackCommand.ringStyle(encoder: encoder, style: style, channel: channel).word
                #expect((word >> 20) & 0xF == 0xB && (10 ... 25).contains(Int((word >> 8) & 0x7F)))
            }
        }
    }
    let invalid: [(String, [String])] = [
        ("ring-display", ["--encoder", "1", "--value", "29", "--channel", "2"]),
        ("ring-display", ["--encoder", "0", "--value", "1", "--channel", "2"]),
        ("ring-display", ["--encoder", "17", "--value", "1", "--channel", "2"]),
        ("ring-display", ["--encoder", "1", "--value", "1"]),
        ("ring-display", ["--encoder", "1", "--style", "1", "--channel", "2"]),
        ("ring-style", ["--encoder", "1", "--style", "5", "--channel", "2"]),
        ("select-layer", ["--layer", "c", "--channel", "2"]),
        ("select-layer", ["--layer", "a", "--channel", "0"]),
        ("select-layer", ["--layer", "a", "--encoder", "1", "--channel", "2"]),
        ("motor", ["--channel", "2"]),
        ("ring-display", ["--cc", "1", "--channel", "2"]),
    ]
    for (name, arguments) in invalid {
        #expect(throws: RemoteMIDIError.self) { _ = try NonMotorFeedbackCommand.parse(name, arguments) }
    }
}
