import Foundation

public enum CaptureReviewError: Error { case invalidFormat, invalidSequence }

/// Validate a frozen JSONL v1 prefix. A valid live prefix is explicitly incomplete;
/// a partial final line, duplicate/end-after-event record or sequence gap is rejected.
public struct CaptureIntegrityReview: Equatable, Sendable {
    public let eventCount: Int
    public let isComplete: Bool

    public init(data: Data) throws {
        guard data.last == 10, let text = String(data: data, encoding: .utf8) else { throw CaptureReviewError.invalidFormat }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        var count = 0
        var started = false
        var ended = false
        for line in lines {
            let object: Any
            do { object = try JSONSerialization.jsonObject(with: Data(line.utf8)) }
            catch { throw CaptureReviewError.invalidFormat }
            guard !line.isEmpty, let row = object as? [String: Any],
                  let kind = row["kind"] as? String, !ended else { throw CaptureReviewError.invalidFormat }
            switch kind {
            case "capture-start":
                guard !started, row["schemaVersion"] as? Int == 1 else { throw CaptureReviewError.invalidFormat }
                started = true
            case "event":
                guard started, row["sequence"] as? Int == count + 1 else { throw CaptureReviewError.invalidSequence }
                count += 1
            case "capture-end":
                guard started, row["eventCount"] as? Int == count else { throw CaptureReviewError.invalidSequence }
                ended = true
            default: throw CaptureReviewError.invalidFormat
            }
        }
        guard started else { throw CaptureReviewError.invalidFormat }
        eventCount = count; isComplete = ended
    }
}
