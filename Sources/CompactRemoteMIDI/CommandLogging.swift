import Foundation

/// Common --log option, stripped before the existing command-specific parser.
/// Paths are local and never interpolated into the SSH command.
public struct RemoteLoggingArguments: Equatable, Sendable {
    public let arguments: [String]
    public let logPath: String?

    public init(_ arguments: [String]) throws {
        var remaining: [String] = []
        var path: String?
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--log" {
                index += 1
                guard path == nil, index < arguments.count, !arguments[index].isEmpty,
                      !arguments[index].hasPrefix("--"), !arguments[index].contains("\0")
                else { throw RemoteMIDIError.missingValue("--log") }
                path = arguments[index]
            } else {
                remaining.append(argument)
            }
            index += 1
        }
        self.arguments = remaining
        logPath = path
    }
}

public enum RemoteEventJSON {
    /// Same canonical JSONL for stdout and the append log. Wall time is recorded at
    /// observation, including MIDI replayed after the fader observation window.
    public static func line(_ fields: [String: Any], at date: Date) throws -> Data {
        var row = fields
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        row["wallClock"] = formatter.string(from: date)
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        data.append(0x0A)
        return data
    }

    /// Transport delivery only; forwarded-to-bridge is not device acknowledgement.
    public static func forwarding(words: [UInt32], direction: String, delivery: String) -> [String: Any] {
        ["event": "midi-forward", "direction": direction, "delivery": delivery,
         "words": words.map { String(format: "%08X", $0) }]
    }
}

public struct FaderObservationSummary: Equatable, Sendable {
    public private(set) var touchMessages = 0
    public private(set) var positionMessages = 0

    /// Count this physical fader on either TX layer, independently of the RX channel.
    public init(command: FaderMoveCommand, words: [UInt32]) {
        for word in words where word >> 28 == 0x2 && (word >> 20) & 0xF == 0xB {
            let number = Int((word >> 8) & 0x7F)
            if number == 100 + command.fader || number == 110 + command.fader {
                touchMessages += 1
            }
            if number == command.fader || number == 27 + command.fader {
                positionMessages += 1
            }
        }
    }

    public var fields: [String: Any] {
        ["touchMessages": touchMessages, "positionMessages": positionMessages]
    }
}
