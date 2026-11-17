import Darwin
import Foundation
import XTouchCompactCore

/// A launcher-owned FIFO. It is never an RPC input route or a MIDI destination.
enum OwnedRehearsalStep: Equatable {
    case input(MIDIMessage, generation: UInt64)
    case disconnect, reconnect, finish
}

enum OwnedRehearsalFailure: String, Error, CustomStringConvertible {
    case invalidPipe, invalidFrame, lineOverflow, bufferOverflow, inputOverflow, receiptOverflow
    case staleGeneration, unexpectedInput, endpointOwnership, transport, cleanup, finishTimeout, terminal
    var description: String {
        "owned-virtual-rehearsal physical_evidence=false: \(rawValue)"
    }
}

final class OwnedRehearsalSteps {
    static let lineLimit = 4096
    static let bufferLimit = 65536
    static let commandLimit = 64
    private let descriptor: Int32
    private var buffer = Data()
    private var ended = false
    private let map: FactoryStandardMap

    init(descriptor: Int32, configuration: CompactHardwareConfiguration) throws {
        var info = stat()
        guard descriptor > STDERR_FILENO, fstat(descriptor, &info) == 0,
              info.st_mode & S_IFMT == S_IFIFO, info.st_uid == getuid()
        else { throw OwnedRehearsalFailure.invalidPipe }
        let originalFlags = fcntl(descriptor, F_GETFL)
        guard originalFlags >= 0, originalFlags & O_ACCMODE != O_WRONLY else { throw OwnedRehearsalFailure.invalidPipe }
        let copy = fcntl(descriptor, F_DUPFD_CLOEXEC, STDERR_FILENO + 1)
        guard copy >= 0 else { throw OwnedRehearsalFailure.invalidPipe }
        let flags = fcntl(copy, F_GETFL)
        guard flags >= 0, fcntl(copy, F_SETFL, flags | O_NONBLOCK) == 0 else {
            close(copy); throw OwnedRehearsalFailure.invalidPipe
        }
        self.descriptor = copy
        map = try FactoryStandardMap(transmitChannel: configuration.transmitChannel, globalReceiveChannel: configuration.receiveChannel)
    }

    deinit { close(descriptor) }

    func drain() throws -> [OwnedRehearsalStep] {
        guard !ended else { return [] }
        var result: [OwnedRehearsalStep] = []
        var readBytes = 0
        while result.count < Self.commandLimit {
            if let newline = buffer.firstIndex(of: 10) {
                let count = buffer.distance(from: buffer.startIndex, to: newline)
                guard count > 0, count <= Self.lineLimit else { throw OwnedRehearsalFailure.lineOverflow }
                let frame = Data(buffer.prefix(count))
                buffer.removeFirst(count + 1)
                let step = try Self.decode(frame, map: map)
                result.append(step)
                if step == .finish {
                    guard buffer.isEmpty else { throw OwnedRehearsalFailure.invalidFrame }
                    ended = true
                    return result
                }
                continue
            }
            guard buffer.count <= Self.lineLimit else { throw OwnedRehearsalFailure.lineOverflow }
            guard buffer.count < Self.bufferLimit else { throw OwnedRehearsalFailure.bufferOverflow }
            if readBytes >= Self.bufferLimit {
                return result
            }
            var bytes = [UInt8](repeating: 0, count: min(4096, Self.bufferLimit - buffer.count))
            let count = read(descriptor, &bytes, bytes.count)
            if count > 0 {
                guard count <= Self.bufferLimit - buffer.count else { throw OwnedRehearsalFailure.bufferOverflow }
                buffer.append(contentsOf: bytes.prefix(count)); readBytes += count
            } else if count == 0 {
                ended = true
                guard buffer.isEmpty else { throw OwnedRehearsalFailure.invalidFrame }
                result.append(.finish)
                return result
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                return result
            } else {
                throw OwnedRehearsalFailure.invalidPipe
            }
        }
        return result
    }

    static func decode(_ frame: Data, map: FactoryStandardMap) throws -> OwnedRehearsalStep {
        guard frame.count <= lineLimit,
              let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let operation = object["operation"] as? String,
              let text = String(data: frame, encoding: .utf8)
        else { throw OwnedRehearsalFailure.invalidFrame }
        // No nested structures are allowed. Count lexical keys as well, rejecting duplicate
        // and escaped duplicate spellings that JSONSerialization would silently overwrite.
        let keys = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"\s*:"#)
        guard keys.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == object.count else { throw OwnedRehearsalFailure.invalidFrame }
        if operation != "input" {
            guard Set(object.keys) == ["operation"] else { throw OwnedRehearsalFailure.invalidFrame }
            switch operation {
            case "disconnect": return .disconnect
            case "reconnect": return .reconnect
            case "finish": return .finish
            default: throw OwnedRehearsalFailure.invalidFrame
            }
        }
        guard Set(object.keys) == ["operation", "control_id", "value", "connection_generation"],
              let id = object["control_id"] as? String,
              let rawGeneration = object["connection_generation"] as? String,
              let generation = UInt64(rawGeneration), String(generation) == rawGeneration
        else { throw OwnedRehearsalFailure.invalidFrame }
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let layer = CompactLayer(rawValue: String(parts[0])),
              let index = Int(parts[2]), String(index) == parts[2]
        else { throw OwnedRehearsalFailure.invalidFrame }
        let control: CompactControl
        let boolean: Bool
        switch parts[1] {
        case "fader": control = .fader(index); boolean = false
        case "encoder": control = .encoder(index); boolean = false
        case "expression": guard index == 1 else { throw OwnedRehearsalFailure.invalidFrame }; control = .expression; boolean = false
        case "touch": control = .faderTouch(index); boolean = true
        case "push": control = .encoderPush(index); boolean = true
        case "button": control = .button(index); boolean = true
        case "footswitch": guard index == 1 else { throw OwnedRehearsalFailure.invalidFrame }; control = .footswitch; boolean = true
        default: throw OwnedRehearsalFailure.invalidFrame
        }
        guard let address = map.inputAddress(for: control, layer: layer), let number = object["value"] as? NSNumber else { throw OwnedRehearsalFailure.invalidFrame }
        let isBoolean = CFGetTypeID(number) == CFBooleanGetTypeID()
        guard isBoolean == boolean else { throw OwnedRehearsalFailure.invalidFrame }
        let value: UInt8
        if boolean {
            value = number.boolValue ? 127 : 0
        } else {
            let scalar = number.doubleValue
            guard scalar.isFinite, scalar.rounded(.towardZero) == scalar, (0 ... 127).contains(scalar) else { throw OwnedRehearsalFailure.invalidFrame }
            value = UInt8(scalar)
        }
        let message: MIDIMessage = switch address.messageType {
        case .controlChange: .controlChange(channel: address.channel, number: address.number, value: value)
        case .note: value == 0 ? .noteOff(channel: address.channel, number: address.number, velocity: 0) : .noteOn(channel: address.channel, number: address.number, velocity: value)
        }
        return .input(message, generation: generation)
    }
}
