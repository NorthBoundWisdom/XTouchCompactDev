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
