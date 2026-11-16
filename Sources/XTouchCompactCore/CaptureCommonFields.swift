import Foundation
import SurfacePluginContracts

public struct CaptureDeviceMismatch: Error, Equatable, Sendable, LocalizedError {
    public let deviceModel: String
    public var errorDescription: String? {
        "Replay refused: capture device \(deviceModel) is not X-TOUCH COMPACT."
    }
}

/// Read-only interchange fields. Other-device extensions stay opaque: no address,
/// layer, profile or runtime is inferred from their bytes or additional metadata.
public struct CaptureCommonEvent: Equatable, Sendable {
    public let sequence: Int
    public let timestamp: String?
    public let source: String
    public let direction: String?
    public let delivery: String?
    public let rawMIDI1Bytes: [UInt8]?
    public let fields: [String: JSONValue]
}

public struct CaptureCommonDocument: Equatable, Sendable {
    public let rawData: Data
    public let session: [String: JSONValue]
    public let events: [CaptureCommonEvent]
    public let integrity: CaptureIntegrityReview
    public var deviceModel: String? {
        session["deviceModel"]?.stringValue
    }

    public var sessionID: String? {
        session["sessionID"]?.stringValue
    }

    public var isForeignDevice: Bool {
        deviceModel.map { $0 != "X-TOUCH COMPACT" } ?? false
    }

    public func requireCompactDevice() throws {
        if let deviceModel, isForeignDevice {
            throw CaptureDeviceMismatch(deviceModel: deviceModel)
        }
    }

    public init(data: Data) throws {
        guard data.count <= RecordedCapture.maximumBytes else { throw CaptureDocumentError.tooLarge }
        let review = try CaptureIntegrityReview(data: data)
        let lines = data.split(separator: 10, omittingEmptySubsequences: false).dropLast()
        let decoder = JSONDecoder()
        var metadata: [String: JSONValue]?, collected: [CaptureCommonEvent] = []
        for (offset, line) in lines.enumerated() {
            do {
                guard let row = try decoder.decode(JSONValue.self, from: Data(line)).objectValue else { throw CaptureDocumentError.invalidRecord(line: offset + 1) }
                if offset == 0 {
                    guard row["kind"] == .string("capture-start"), row["schemaVersion"]?.exactIntValue == 1,
                          let session = row["session"]?.objectValue else { throw CaptureDocumentError.invalidRecord(line: 1) }
                    metadata = session
                }
                if row["kind"] == .string("capture-end") {
                    guard row["eventCount"]?.exactIntValue == collected.count else { throw CaptureDocumentError.invalidRecord(line: offset + 1) }
                }
                guard row["kind"] == .string("event") else { continue }
                guard collected.count < RecordedCapture.maximumEvents else { throw CaptureDocumentError.tooManyEvents }
                guard let sequence = row["sequence"]?.exactIntValue, sequence == collected.count + 1,
                      let source = row["source"]?.stringValue, ["mock", "hardware", "agent", "application"].contains(source)
                else { throw CaptureDocumentError.invalidRecord(line: offset + 1) }
                func string(_ key: String) throws -> String? {
                    guard let value = row[key], value != .null else { return nil }
                    guard let text = value.stringValue else { throw CaptureDocumentError.invalidRecord(line: offset + 1) }
                    return text
                }
                let direction = try string("direction")
                guard direction == nil || direction == "IN" || direction == "OUT" else { throw CaptureDocumentError.invalidRecord(line: offset + 1) }
                if let ignored = row["ignored"], ignored != .null, ignored.boolValue == nil {
                    throw CaptureDocumentError.invalidRecord(line: offset + 1)
                }
                let raw = try row["rawMIDI1Bytes"].flatMap { value -> [UInt8]? in
                    value == .null ? nil : try value.decoded([UInt8].self)
                }
                try collected.append(CaptureCommonEvent(sequence: sequence, timestamp: string("timestamp"), source: source,
                                                        direction: direction, delivery: string("delivery"), rawMIDI1Bytes: raw, fields: row))
            } catch let error as CaptureDocumentError { throw error }
            catch { throw CaptureDocumentError.invalidRecord(line: offset + 1) }
        }
        guard let metadata else { throw CaptureDocumentError.invalidRecord(line: 1) }
        rawData = data; session = metadata; events = collected; integrity = review
    }
}
