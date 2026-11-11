#if os(macOS)
    import Foundation
    import XTouchCompactCore

    /// Streaming JSON Lines is independent of the bounded on-screen monitor.
    /// Bytes are canonical MIDI 1 bytes from the decoded CoreMIDI message, not a UMP packet dump.
    final class MonitorCapture {
        private let writer: any EvidenceWriting
        private var sequence = 0
        private var closed = false

        init(url: URL, started: Date, metadata: CaptureSessionMetadata = .init(),
             writerFactory: (URL) throws -> any EvidenceWriting = { try ExclusiveEvidenceFile(url: $0) }) throws
        {
            writer = try writerFactory(url)
            do {
                try write(["kind": "capture-start", "schemaVersion": 1, "timestamp": timestamp(started),
                           "session": metadata.json,
                           "byteFormat": "canonical MIDI 1; unsupported UMP/SysEx/realtime are not captured"])
            } catch {
                try? writer.close()
                throw error
            }
        }

        deinit { try? writer.close() }

        func append(_ event: MonitorEvent, map: FactoryStandardMap, lightProtocol: ButtonLightProtocol,
                    hardwareMode: Bool, listenOnly: Bool) throws
        {
            guard !closed else { throw CocoaError(.fileWriteUnknown) }
            var row: [String: Any] = [
                "kind": "event", "sequence": sequence + 1, "timestamp": timestamp(event.timestamp),
                "source": event.source.rawValue, "hostLayer": event.hostLayer.rawValue,
                "hardwareMode": hardwareMode, "listenOnly": listenOnly, "ignored": event.ignored,
                "transmitChannel": Int(map.transmitChannel) + 1,
                "globalReceiveChannel": Int(map.globalReceiveChannel) + 1,
                "ledProtocol": lightProtocol.rawValue,
            ]
            row["direction"] = event.direction?.rawValue
            row["delivery"] = event.delivery?.rawValue
            row["deviceLayer"] = event.deviceLayer?.rawValue
            row["control"] = event.control?.description
            row["rawMIDI1Bytes"] = event.message?.midi1Bytes
            row["message"] = event.message?.description
            if event.direction == .input, let message = event.message, let decoded = map.decode(message) {
                var input: [String: Any] = ["control": decoded.control.description,
                                            "layer": decoded.layer.rawValue, "value": Int(decoded.value)]
                input["isPressed"] = decoded.isPressed
                row["decoded"] = input
            }
            try write(row)
            sequence += 1
        }

        func finish(at time: Date) throws {
            guard !closed else { return }
            // Flush events before writing the completion marker. A failed event write
            // or flush must not be turned into a completed capture by a later stop.
            do {
                try writer.synchronize()
                try write(["kind": "capture-end", "timestamp": timestamp(time), "eventCount": sequence])
                try writer.synchronize(); try writer.close(); closed = true
            } catch {
                closed = true; try? writer.close(); throw error
            }
        }

        private func timestamp(_ date: Date) -> String {
            date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true).timeZone(separator: .colon))
        }

        private func write(_ row: [String: Any]) throws {
            var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            data.append(0x0A)
            do { try writer.write(data) }
            catch { closed = true; try? writer.close(); throw error }
        }
    }
#endif
