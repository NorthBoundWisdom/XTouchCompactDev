import Foundation

public enum CaptureDocumentError: Error, Equatable, Sendable {
    case tooLarge, tooManyEvents, invalidRecord(line: Int)
}

public struct CaptureRoute: Equatable, Sendable, Decodable {
    public let inputID: Int?
    public let outputID: Int?
    public let generation: UInt64?
    public var isKnown: Bool {
        inputID != nil && outputID != nil && generation != nil
    }

    private enum CodingKeys: String, CodingKey { case connectedInput, connectedOutput, generation }
    init(inputID: Int?, outputID: Int?, generation: UInt64?) {
        self.inputID = inputID; self.outputID = outputID; self.generation = generation
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputID = try c.decode(CaptureEndpoint?.self, forKey: .connectedInput)?.id
        outputID = try c.decode(CaptureEndpoint?.self, forKey: .connectedOutput)?.id
        generation = try c.decode(UInt64?.self, forKey: .generation)
    }
}

private struct CaptureEndpoint: Decodable {
    let id: Int
    private enum CodingKeys: String, CodingKey { case id }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        guard id != 0 else { throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Zero endpoint") }
    }
}

public struct CaptureSessionFacts: Equatable, Sendable, Decodable {
    public let route: CaptureRoute
    public let hardwareMode: Bool?
    /// Recorded configured channels, 1...16. Nil is unavailable, never inferred from TX.
    public let transmitChannel: UInt8?
    public let receiveChannel: UInt8?
    public let lightProtocol: ButtonLightProtocol?
    public let sourceRevision: String?

    private enum CodingKeys: String, CodingKey {
        case connectedInput, connectedOutput, connectionGeneration, hardwareMode
        case configuredTransmitChannel, configuredGlobalReceiveChannel, ledProtocol, sourceRevision
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        route = try CaptureRoute(inputID: c.decode(CaptureEndpoint?.self, forKey: .connectedInput)?.id,
                                 outputID: c.decode(CaptureEndpoint?.self, forKey: .connectedOutput)?.id,
                                 generation: c.decode(UInt64?.self, forKey: .connectionGeneration))
        hardwareMode = try c.decode(Bool?.self, forKey: .hardwareMode)
        transmitChannel = try c.decode(UInt8?.self, forKey: .configuredTransmitChannel)
        receiveChannel = try c.decodeIfPresent(UInt8.self, forKey: .configuredGlobalReceiveChannel)
        lightProtocol = try c.decodeIfPresent(ButtonLightProtocol.self, forKey: .ledProtocol)
        sourceRevision = try c.decodeIfPresent(String.self, forKey: .sourceRevision)
        guard [transmitChannel, receiveChannel].allSatisfy({ $0.map { (1 ... 16).contains($0) } ?? true }) else {
            throw DecodingError.dataCorruptedError(forKey: .configuredTransmitChannel, in: c, debugDescription: "Invalid channel")
        }
    }
}

public struct RecordedCaptureEvent: Equatable, Sendable, Decodable {
    public enum Source: String, Sendable, Decodable { case hardware, mock, agent, application }
    public enum Direction: String, Sendable, Decodable { case input = "IN", output = "OUT" }
    public let sequence: Int
    public let timestamp: String?
    public let source: Source
    public let hardwareMode: Bool
    public let hostLayer: CompactLayer
    public let transmitChannel: UInt8
    public let receiveChannel: UInt8?
    public let lightProtocol: ButtonLightProtocol?
    public let ignored: Bool
    public let direction: Direction?
    public let delivery: String?
    public let rawMIDI1Bytes: [UInt8]?
    public let connection: CaptureRoute?

    public var message: MIDIMessage? {
        guard let bytes = rawMIDI1Bytes else { return nil }
        let channel = bytes[0] & 0xF, number = bytes[1]
        switch bytes[0] & 0xF0 {
        case 0x80: return .noteOff(channel: channel, number: number, velocity: bytes[2])
        case 0x90: return .noteOn(channel: channel, number: number, velocity: bytes[2])
        case 0xB0: return .controlChange(channel: channel, number: number, value: bytes[2])
        case 0xC0: return .programChange(channel: channel, number: number)
        case 0xE0: return .pitchBend(channel: channel, value: UInt16(number) | UInt16(bytes[2]) << 7)
        default: return nil // Valid canonical but unsupported Standard MIDI control input.
        }
    }

    public var decodedInput: CompactInput? {
        guard let message else { return nil }
        return try? FactoryStandardMap(transmitChannel: transmitChannel - 1).decode(message)
    }

    public var motorFader: Int? {
        guard let bytes = rawMIDI1Bytes, bytes[0] & 0xF0 == 0xB0, (1 ... 9).contains(bytes[1]) else { return nil }
        return Int(bytes[1])
    }

    public var isLayerAssertion: Bool {
        guard let bytes = rawMIDI1Bytes else { return false }
        return bytes[0] & 0xF0 == 0xC0 && bytes[1] < 2
    }

    private enum CodingKeys: String, CodingKey {
        case sequence, timestamp, source, hardwareMode, hostLayer, transmitChannel, globalReceiveChannel
        case ledProtocol, ignored, direction, delivery, rawMIDI1Bytes, connection
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sequence = try c.decode(Int.self, forKey: .sequence)
        timestamp = try c.decodeIfPresent(String.self, forKey: .timestamp)
        source = try c.decode(Source.self, forKey: .source)
        hardwareMode = try c.decode(Bool.self, forKey: .hardwareMode)
        hostLayer = try c.decode(CompactLayer.self, forKey: .hostLayer)
        transmitChannel = try c.decode(UInt8.self, forKey: .transmitChannel)
        receiveChannel = try c.decodeIfPresent(UInt8.self, forKey: .globalReceiveChannel)
        lightProtocol = try c.decodeIfPresent(ButtonLightProtocol.self, forKey: .ledProtocol)
        ignored = try c.decode(Bool.self, forKey: .ignored)
        direction = try c.decodeIfPresent(Direction.self, forKey: .direction)
        delivery = try c.decodeIfPresent(String.self, forKey: .delivery)
        rawMIDI1Bytes = try c.decodeIfPresent([UInt8].self, forKey: .rawMIDI1Bytes)
        connection = c.contains(.connection) ? try c.decode(CaptureRoute.self, forKey: .connection) : nil
        let channelValid = (1 ... 16).contains(transmitChannel) && (receiveChannel.map { (1 ... 16).contains($0) } ?? true)
        guard channelValid else { throw DecodingError.dataCorruptedError(forKey: .transmitChannel, in: c, debugDescription: "Invalid channel") }
        if let raw = rawMIDI1Bytes {
            guard direction != nil, raw.count >= 2, (0x80 ..< 0xF0).contains(raw[0]),
                  raw.count == ([UInt8(0xC0), 0xD0].contains(raw[0] & 0xF0) ? 2 : 3),
                  raw.dropFirst().allSatisfy({ $0 < 128 })
            else {
                throw DecodingError.dataCorruptedError(forKey: .rawMIDI1Bytes, in: c, debugDescription: "Invalid canonical MIDI")
            }
            if source != .mock, direction == .input, source != .hardware || delivery != "received" {
                throw DecodingError.dataCorruptedError(forKey: .source, in: c, debugDescription: "Invalid input source/delivery")
            }
            if source == .hardware, direction == .output, !hardwareMode {
                throw DecodingError.dataCorruptedError(forKey: .hardwareMode, in: c, debugDescription: "Contradictory output mode")
            }
        } else if direction != nil {
            throw DecodingError.dataCorruptedError(forKey: .rawMIDI1Bytes, in: c, debugDescription: "Missing MIDI")
        }
    }
}

/// A bounded immutable capture prefix, independent of CoreMIDI, App state or file writers.
public struct RecordedCapture: Equatable, Sendable {
    public static let maximumBytes = 16 * 1024 * 1024
    public static let maximumEvents = 100_000
    public let session: CaptureSessionFacts
    public let events: [RecordedCaptureEvent]
    public let isComplete: Bool

    public init(data: Data, byteLimit: Int = maximumBytes, eventLimit: Int = maximumEvents) throws {
        guard data.count <= byteLimit else { throw CaptureDocumentError.tooLarge }
        guard data.last == 10, let text = String(data: data, encoding: .utf8) else { throw CaptureDocumentError.invalidRecord(line: 1) }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        let decoder = JSONDecoder()
        var captured: [RecordedCaptureEvent] = [], facts: CaptureSessionFacts?, complete = false
        struct Envelope: Decodable { let kind: String; let schemaVersion: Int?; let session: CaptureSessionFacts?; let eventCount: Int? }
        for (index, line) in lines.enumerated() {
            do {
                let bytes = Data(line.utf8)
                let row = try decoder.decode(Envelope.self, from: bytes)
                guard !complete else { throw CaptureDocumentError.invalidRecord(line: index + 1) }
                switch row.kind {
                case "capture-start":
                    guard index == 0, row.schemaVersion == 1, let session = row.session else { throw CaptureDocumentError.invalidRecord(line: index + 1) }
                    facts = session
                case "event":
                    guard facts != nil else { throw CaptureDocumentError.invalidRecord(line: index + 1) }
                    guard captured.count < eventLimit else { throw CaptureDocumentError.tooManyEvents }
                    let event = try decoder.decode(RecordedCaptureEvent.self, from: bytes)
                    guard event.sequence == captured.count + 1 else { throw CaptureDocumentError.invalidRecord(line: index + 1) }
                    captured.append(event)
                case "capture-end":
                    guard facts != nil, row.eventCount == captured.count else { throw CaptureDocumentError.invalidRecord(line: index + 1) }
                    complete = true
                default: throw CaptureDocumentError.invalidRecord(line: index + 1)
                }
            } catch let error as CaptureDocumentError { throw error }
            catch { throw CaptureDocumentError.invalidRecord(line: index + 1) }
        }
        guard let facts else { throw CaptureDocumentError.invalidRecord(line: 1) }
        session = facts; events = captured; isComplete = complete
    }
}
