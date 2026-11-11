#if os(macOS)
    import CryptoKit
    import Foundation
    import XTouchCompactCore

    struct InputReviewExportReceipt: Equatable, Sendable {
        let path: String
        let sha256: String
        let captureSnapshotPath: String?
    }

    /// Export explicit observation scope plus an independently fingerprinted raw capture
    /// snapshot. The capture can include inputs before reset or omit later unrecorded inputs.
    enum InputReviewExporter {
        static func export(to url: URL, observer: CompactInputObserver, observationStarted: Date?,
                           captureURL: URL?, metadata: CaptureSessionMetadata, at time: Date) throws -> InputReviewExportReceipt
        {
            let snapshotURL = url.deletingPathExtension().appendingPathExtension("capture.jsonl")
            let checksumURL = url.appendingPathExtension("sha256")
            let source = try captureURL.map { try Data(contentsOf: $0) }
            let integrity = try source.map(CaptureIntegrityReview.init(data:))
            let outputURLs = [url, checksumURL] + (source == nil ? [] : [snapshotURL])
            guard Set(outputURLs.map(\.standardizedFileURL)).count == outputURLs.count else { throw EvidenceError.fileExists }
            for target in outputURLs {
                if FileManager.default.fileExists(atPath: target.path) ||
                    (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil
                {
                    throw EvidenceError.fileExists
                }
            }
            var context = metadata.json
            context["contextID"] = context.removeValue(forKey: "sessionID")
            var report: [String: Any] = [
                "kind": "xtouch.input-review", "schemaVersion": 1, "generatedAt": timestamp(time),
                "currentContext": context, "hardwareAcceptance": NSNull(),
                "observationStartedAt": observationStarted.map(timestamp) as Any? ?? NSNull(),
                "observationMessageCount": observer.messageCount,
                "observationScope": "since last observation reset; coverage is not hardware sign-off",
                "captureScope": "independent raw snapshot; may include earlier inputs or omit later unrecorded inputs",
                "layers": CompactLayer.allCases.map { layer in
                    ["layer": layer.rawValue, "groups": CompactInputGroup.allCases.map { group in
                        ["group": group.rawValue, "controls": group.controls.map { control in
                            controlJSON(control, review: observer.reviews[layer]?[control])
                        }] as [String: Any]
                    }] as [String: Any]
                },
                "crossLayerReleases": observer.crossLayerReleases.sorted {
                    transitionKey($0.key) < transitionKey($1.key)
                }.map { transition, count in
                    ["control": transition.control.description, "pressedLayer": transition.pressedLayer.rawValue,
                     "releasedLayer": transition.releasedLayer.rawValue,
                     "interveningLayer": transition.interveningLayer?.rawValue as Any? ?? NSNull(), "count": count] as [String: Any]
                },
            ]
            if let source, let integrity, let captureURL {
                let header = try JSONSerialization.jsonObject(with: Data(source.prefix { $0 != 10 })) as? [String: Any]
                let sourceSession = (header?["session"] as? [String: Any])?["sessionID"] as? String
                report["capture"] = ["sourceFile": captureURL.lastPathComponent, "snapshotFile": snapshotURL.lastPathComponent,
                                     "sessionID": sourceSession as Any? ?? NSNull(),
                                     "sha256": digest(source), "byteCount": source.count,
                                     "eventCount": integrity.eventCount, "complete": integrity.isComplete]
            } else {
                report["capture"] = NSNull()
            }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            if let source {
                try write(source, to: snapshotURL)
            }
            try write(data, to: url)
            let hash = digest(data)
            try write(Data("\(hash)  \(url.lastPathComponent)\n".utf8), to: checksumURL)
            return InputReviewExportReceipt(path: url.path, sha256: hash, captureSnapshotPath: source == nil ? nil : snapshotURL.path)
        }

        private static func controlJSON(_ control: CompactControl, review: ControlInputReview?) -> [String: Any] {
            let review = review ?? .init()
            return ["control": control.description, "eventCount": review.eventCount,
                    "minimum": review.minimum as Any? ?? NSNull(), "maximum": review.maximum as Any? ?? NSNull(),
                    "pressCount": review.pressCount, "releaseCount": review.releaseCount, "pairCount": review.pairCount,
                    "duplicatePressCount": review.duplicatePressCount, "unmatchedReleaseCount": review.unmatchedReleaseCount,
                    "isDown": review.isDown as Any? ?? NSNull(), "addresses": review.addresses.map(\.description).sorted(),
                    "lastReceived": review.lastReceived.map(timestamp) as Any? ?? NSNull()]
        }

        private static func transitionKey(_ value: CrossLayerRelease) -> String {
            value.control.description + value.pressedLayer.rawValue + value.releasedLayer.rawValue + (value.interveningLayer?.rawValue ?? "-")
        }

        private static func timestamp(_ time: Date) -> String {
            time.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon))
        }

        private static func digest(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        private static func write(_ data: Data, to url: URL) throws {
            let writer = try ExclusiveEvidenceFile(url: url)
            defer { try? writer.close() }
            try writer.write(data); try writer.synchronize(); try writer.close()
        }
    }
#endif
