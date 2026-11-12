import Foundation

/// Development-only remote hardware. `XTouchRemoteMIDI client` on the developer's Mac
/// starts `XTouchRemoteMIDI bridge` on the Mac with the controller plugged in, over SSH
/// (stdin/stdout, so no listening port and SSH owns authentication). The client publishes
/// virtual CoreMIDI endpoints named like the device. Neither side parses, filters,
/// synthesizes or acknowledges MIDI: all safety policy stays in the app.
public enum RemoteMIDIDefaults {
    public static let deviceName = "X-TOUCH COMPACT"
    public static let remoteBinary = ".xtouch-remote/XTouchRemoteMIDI"
    /// Virtual endpoints are named "X-TOUCH COMPACT (via <host>)" so the app's automatic
    /// device match still applies and every capture records that the route was remote.
    public static let viaMarker = " (via "
    public static let pingInterval: TimeInterval = 2
    public static let silenceTimeout: TimeInterval = 6

    public static func endpointName(device: String = deviceName, host: String) -> String {
        device + viaMarker + host + ")"
    }

    /// The bridge host for a remote endpoint name, or nil for a locally attached port.
    public static func bridgeHost(fromEndpointName name: String) -> String? {
        guard name.hasSuffix(")"), let range = name.range(of: viaMarker, options: .backwards) else { return nil }
        let host = name[range.upperBound ..< name.index(before: name.endIndex)]
        return host.isEmpty ? nil : String(host)
    }

    /// Stable, positive CoreMIDI unique IDs so saved port selections survive reconnects.
    public static func endpointUniqueID(host: String, isSource: Bool) -> Int32 {
        var hash: UInt32 = 2_166_136_261
        for byte in ((isSource ? "src:" : "dst:") + host.lowercased()).utf8 {
            hash = (hash ^ UInt32(byte)) &* 16_777_619
        }
        return Int32(bitPattern: (hash & 0x3FFF_FFFF) | 0x4000_0000)
    }
}

public enum RemoteMIDIError: Error, Equatable, Sendable {
    case invalidHost(String)
    case invalidPath(String)
    case missingValue(String)
    case unknownArgument(String)
    case missingArgument(String)
    case protocolViolation(String)
}

extension RemoteMIDIError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .invalidHost(host): "Invalid SSH host: \(host)"
        case let .invalidPath(path): "Invalid remote binary path: \(path)"
        case let .missingValue(flag): "Missing or invalid value for \(flag)"
        case let .unknownArgument(argument): "Unknown argument: \(argument)"
        case let .missingArgument(flag): "\(flag) is required"
        case let .protocolViolation(reason): "Remote MIDI protocol violation: \(reason)"
        }
    }
}

/// SSH host alias, DNS name or address. Option-like or shell-active text is rejected
/// because the value is passed to ssh(1).
public func validatedRemoteHost(_ text: String) throws -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_:@")
    guard !text.isEmpty, text.count <= 253, text.unicodeScalars.allSatisfy(allowed.contains),
          !text.hasPrefix("-"), !text.hasPrefix("."), !text.hasPrefix("@"), text.filter({ $0 == "@" }).count <= 1
    else { throw RemoteMIDIError.invalidHost(text) }
    return text
}

/// Remote command path: relative to the remote home or absolute, shell-inert characters only.
public func validatedRemotePath(_ text: String) throws -> String {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._/-")
    guard !text.isEmpty, text.count <= 512, text.unicodeScalars.allSatisfy(allowed.contains),
          !text.hasPrefix("-"), !text.split(separator: "/").contains(".."), !text.hasSuffix("/")
    else { throw RemoteMIDIError.invalidPath(text) }
    return text
}

private func validatedDeviceName(_ value: String, flag: String) throws -> String {
    let name = value.trimmingCharacters(in: .whitespaces)
    // The name is single-quoted into the remote command line: no quotes or control characters.
    guard !name.isEmpty, name.count <= 64, !name.contains(RemoteMIDIDefaults.viaMarker), !name.contains("'"),
          !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else {
        throw RemoteMIDIError.missingValue(flag)
    }
    return name
}

private struct ArgumentReader {
    var iterator: IndexingIterator<[String]>
    mutating func next() -> String? {
        iterator.next()
    }

    mutating func value(for flag: String) throws -> String {
        guard let next = iterator.next(), !next.hasPrefix("--") else { throw RemoteMIDIError.missingValue(flag) }
        return next
    }
}

/// `XTouchRemoteMIDI bridge [--device NAME] [--status PATH]` — runs beside the controller.
public struct RemoteBridgeOptions: Equatable, Sendable {
    public var deviceName = RemoteMIDIDefaults.deviceName
    public var statusPath: String?
    /// Never write to the controller: host-to-device frames are counted and dropped.
    public var listenOnly = false

    public init(deviceName: String = RemoteMIDIDefaults.deviceName, statusPath: String? = nil, listenOnly: Bool = false) {
        self.deviceName = deviceName; self.statusPath = statusPath; self.listenOnly = listenOnly
    }

    public static func parse(_ arguments: [String]) throws -> Self {
        var reader = ArgumentReader(iterator: arguments.makeIterator())
        var options = Self()
        while let argument = reader.next() {
            switch argument {
            case "--device": options.deviceName = try validatedDeviceName(reader.value(for: argument), flag: argument)
            case "--status": options.statusPath = try reader.value(for: argument)
            case "--listen-only": options.listenOnly = true
            default: throw RemoteMIDIError.unknownArgument(argument)
            }
        }
        return options
    }

    /// Matches the physical controller only; a remote endpoint is never re-exported.
    public func matchesDevice(_ endpointName: String) -> Bool {
        endpointName.uppercased().contains(deviceName.uppercased())
            && RemoteMIDIDefaults.bridgeHost(fromEndpointName: endpointName) == nil
    }
}

/// `XTouchRemoteMIDI client --ssh HOST [--remote-binary PATH] [--label NAME] [--device NAME]`
public struct RemoteClientOptions: Equatable, Sendable {
    public var sshHost: String
    public var remoteBinary = RemoteMIDIDefaults.remoteBinary
    public var label: String
    public var deviceName = RemoteMIDIDefaults.deviceName
    /// Drop everything the local app sends, on both ends of the link.
    public var listenOnly = false

    public var endpointName: String {
        RemoteMIDIDefaults.endpointName(device: deviceName, host: label)
    }

    /// ssh(1) arguments. BatchMode never falls back to a password prompt; keepalives and
    /// the bridge's own pings bound how long a dead link can look alive.
    public var sshArguments: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "-o", "ServerAliveInterval=5",
         "-o", "ServerAliveCountMax=2", "-T", "--", sshHost,
         remoteBinary, "bridge", "--device", "'\(deviceName)'"] + (listenOnly ? ["--listen-only"] : [])
    }

    public static func parse(_ arguments: [String]) throws -> Self {
        var reader = ArgumentReader(iterator: arguments.makeIterator())
        var host: String?
        var binary = RemoteMIDIDefaults.remoteBinary
        var label: String?
        var device = RemoteMIDIDefaults.deviceName
        var listenOnly = false
        while let argument = reader.next() {
            switch argument {
            case "--listen-only": listenOnly = true
            case "--ssh": host = try validatedRemoteHost(reader.value(for: argument))
            case "--remote-binary": binary = try validatedRemotePath(reader.value(for: argument))
            case "--label": label = try validatedRemoteHost(reader.value(for: argument))
            case "--device":
                device = try validatedDeviceName(reader.value(for: argument), flag: argument)
            default: throw RemoteMIDIError.unknownArgument(argument)
            }
        }
        guard let host else { throw RemoteMIDIError.missingArgument("--ssh") }
        let bareHost = host.split(separator: "@").last.map(String.init) ?? host
        return Self(sshHost: host, remoteBinary: binary, label: label ?? bareHost, deviceName: device, listenOnly: listenOnly)
    }
}

/// `XTouchRemoteMIDI button-light --button N --velocity V --channel C [--device NAME]`
///
/// The only sender in this tool, for the hardware bring-up LED-encoding check. It can express
/// nothing but one button-LED Note On: buttons 1…39 (RX notes 0…38), velocities 0…3 (the
/// union of the manual 0/1/2 and observed-1.14 0/2/3 encodings). It cannot produce a
/// Control Change, so it can never address a motor, a ring or the mode switch.
public struct ButtonLightCommand: Equatable, Sendable {
    public var button: Int
    public var velocity: Int
    /// Global RX channel as shown to people, 1…16. Never inferred; always given explicitly.
    public var channel: Int
    public var deviceName = RemoteMIDIDefaults.deviceName

    public static func parse(_ arguments: [String]) throws -> Self {
        var reader = ArgumentReader(iterator: arguments.makeIterator())
        var button: Int?
        var velocity: Int?
        var channel: Int?
        var device = RemoteMIDIDefaults.deviceName
        while let argument = reader.next() {
            switch argument {
            case "--button": button = try Int(reader.value(for: argument))
            case "--velocity": velocity = try Int(reader.value(for: argument))
            case "--channel": channel = try Int(reader.value(for: argument))
            case "--device": device = try validatedDeviceName(reader.value(for: argument), flag: argument)
            default: throw RemoteMIDIError.unknownArgument(argument)
            }
        }
        guard let button, (1 ... 39).contains(button) else { throw RemoteMIDIError.missingValue("--button") }
        guard let velocity, (0 ... 3).contains(velocity) else { throw RemoteMIDIError.missingValue("--velocity") }
        guard let channel, (1 ... 16).contains(channel) else { throw RemoteMIDIError.missingValue("--channel") }
        return Self(button: button, velocity: velocity, channel: channel, deviceName: device)
    }

    /// MIDI 1.0 UMP word: Note On, note = button − 1, on the given channel.
    public var word: UInt32 {
        let status = UInt32(0x90 | (channel - 1))
        let note = UInt32(button - 1)
        return 0x2000_0000 | (status << 16) | (note << 8) | UInt32(velocity)
    }
}

// MARK: - Wire protocol

/// Frames on the SSH stdio stream are `[kind u8][length u16 big-endian][payload]`. MIDI payloads are one CoreMIDI
/// MIDI 1.0 UMP packet (1…64 big-endian words), forwarded verbatim in both directions.
public enum RemoteFrame: Equatable, Sendable {
    case hello(version: UInt8)
    case midi(words: [UInt32])
    /// Bridge → client: whether the physical controller's input and output are present.
    case device(source: Bool, destination: Bool)
    case ping

    public static let magic: [UInt8] = Array("XTRM".utf8)
    public static let version: UInt8 = 1
    public static let maximumWords = 64

    public var encoded: [UInt8] {
        let (kind, payload): (UInt8, [UInt8]) = switch self {
        case let .hello(version): (1, Self.magic + [version])
        case let .midi(words): (2, words.flatMap(bigEndianBytes))
        case let .device(source, destination): (3, [source ? 1 : 0, destination ? 1 : 0])
        case .ping: (4, [])
        }
        return [kind, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload
    }
}

/// Spelled out step by step: chained shifts in one expression exceed older compilers'
/// type-checking time limit (Swift 6.2 on Linux, Xcode 26.6 on CI).
private func bigEndianBytes(_ word: UInt32) -> [UInt8] {
    let b0 = UInt8(truncatingIfNeeded: word >> 24)
    let b1 = UInt8(truncatingIfNeeded: word >> 16)
    let b2 = UInt8(truncatingIfNeeded: word >> 8)
    let b3 = UInt8(truncatingIfNeeded: word)
    return [b0, b1, b2, b3]
}

private func bigEndianWord(_ bytes: [UInt8], at offset: Int) -> UInt32 {
    var word: UInt32 = 0
    for index in offset ..< offset + 4 {
        word = (word << 8) | UInt32(bytes[index])
    }
    return word
}

/// Incremental decoder. Any malformed input is a fatal protocol error for the connection.
public struct RemoteFrameDecoder: Sendable {
    private var buffer: [UInt8] = []
    public init() {}

    public mutating func append(_ bytes: some Sequence<UInt8>) throws -> [RemoteFrame] {
        buffer.append(contentsOf: bytes)
        var frames: [RemoteFrame] = []
        while buffer.count >= 3 {
            let kind = buffer[0]
            let length = Int(buffer[1]) << 8 | Int(buffer[2])
            guard length <= RemoteFrame.maximumWords * 4 else { throw RemoteMIDIError.protocolViolation("frame too large") }
            guard buffer.count >= 3 + length else { break }
            let payload = Array(buffer[3 ..< 3 + length])
            buffer.removeFirst(3 + length)
            try frames.append(Self.frame(kind: kind, payload: payload))
        }
        return frames
    }

    private static func frame(kind: UInt8, payload: [UInt8]) throws -> RemoteFrame {
        switch kind {
        case 1:
            guard payload.count == 5, Array(payload.prefix(4)) == RemoteFrame.magic else {
                throw RemoteMIDIError.protocolViolation("bad hello")
            }
            return .hello(version: payload[4])
        case 2:
            guard !payload.isEmpty, payload.count % 4 == 0 else { throw RemoteMIDIError.protocolViolation("bad MIDI payload") }
            var words: [UInt32] = []
            words.reserveCapacity(payload.count / 4)
            for offset in stride(from: 0, to: payload.count, by: 4) {
                words.append(bigEndianWord(payload, at: offset))
            }
            return .midi(words: words)
        case 3:
            guard payload.count == 2, payload.allSatisfy({ $0 <= 1 }) else { throw RemoteMIDIError.protocolViolation("bad device status") }
            return .device(source: payload[0] == 1, destination: payload[1] == 1)
        case 4:
            guard payload.isEmpty else { throw RemoteMIDIError.protocolViolation("bad ping") }
            return .ping
        default:
            throw RemoteMIDIError.protocolViolation("unknown frame kind \(kind)")
        }
    }
}

/// Bridge status, optionally written atomically beside the controller for diagnosis.
public struct RemoteBridgeStatus: Codable, Equatable, Sendable {
    public var pid: Int32
    public var running: Bool
    public var deviceSource: String?
    public var deviceDestination: String?
    public var framesToClient: UInt64
    public var framesToDevice: UInt64
    public var framesDropped: UInt64
    public var updatedAt: Date

    public init(pid: Int32, running: Bool, deviceSource: String? = nil, deviceDestination: String? = nil,
                framesToClient: UInt64 = 0, framesToDevice: UInt64 = 0, framesDropped: UInt64 = 0, updatedAt: Date)
    {
        self.pid = pid; self.running = running; self.deviceSource = deviceSource
        self.deviceDestination = deviceDestination; self.framesToClient = framesToClient
        self.framesToDevice = framesToDevice; self.framesDropped = framesDropped; self.updatedAt = updatedAt
    }

    public static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
