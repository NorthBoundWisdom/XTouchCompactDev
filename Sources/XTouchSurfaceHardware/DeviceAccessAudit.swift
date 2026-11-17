import Foundation
import SurfaceControlContracts
import XTouchCompactCore

/// Counts actual CoreMIDI call sites, not successful device state or inferred observations.
final class DeviceAccessAudit: @unchecked Sendable {
    private let lock = NSLock()
    let access: HardwareDeviceAccess
    let rehearsal: Bool
    private var counters: [String: Int] = ["coremidi_factory_calls": 0, "scripted_factory_calls": 0,
                                           "client_create_calls": 0, "input_port_create_calls": 0, "output_port_create_calls": 0,
                                           "source_enumeration_calls": 0, "destination_enumeration_calls": 0,
                                           "source_connect_calls": 0, "midi_send_calls": 0, "accepted_messages": 0]
    init(access: HardwareDeviceAccess, rehearsal: Bool = false) {
        self.access = access
        self.rehearsal = rehearsal
    }

    func increment(_ key: String) {
        lock.lock(); defer { lock.unlock() }
        counters[key, default: 0] += 1
    }

    var snapshot: [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return counters
    }

    func line(_ event: String, operation: String? = nil) -> Data {
        var fields: [String: Any] = ["event": event, "device_access": access.rawValue,
                                     "diagnostic_only": access == .disabled, "device_io": snapshot]
        if rehearsal {
            fields["owned_virtual_rehearsal"] = true
            fields["physical_evidence"] = false
        }
        if let operation {
            fields["operation"] = operation
        }
        return (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])).map { $0 + Data("\n".utf8) } ?? Data()
    }

    func emitOwned(_ event: String, origin: HardwareEndpointOrigin, word: UInt32? = nil, ticket: UInt64? = nil, accepted: Bool? = nil, receivedAt: Double? = nil, ownerAccepted: Bool? = nil, packetTimestamp: UInt64? = nil) {
        guard rehearsal else { return }
        var fields = (try? JSONSerialization.jsonObject(with: line(event))) as? [String: Any] ?? [:]
        fields["endpoint_origin"] = ["input_id": origin.inputID.map { $0 as Any } ?? NSNull(), "output_id": origin.outputID.map { $0 as Any } ?? NSNull(),
                                     "connection_generation": String(origin.connectionGeneration), "transport_origin": origin.transportOrigin]
        if let word {
            fields["word"] = String(format: "%08x", word)
        }
        if let ticket {
            fields["ticket"] = String(ticket)
        }
        if let accepted {
            fields["transport_accepted"] = accepted
        }
        if let receivedAt {
            fields["received_monotonic"] = receivedAt
        }
        if let ownerAccepted {
            fields["owner_accepted"] = ownerAccepted
        }
        if let packetTimestamp {
            fields["packet_timestamp"] = String(packetTimestamp)
        }
        if let body = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
            FileHandle.standardError.write(body + Data([10]))
        }
    }

    func emitUnattributed(_ evidence: OwnedReceiptEvidence) {
        guard rehearsal else { return }
        var fields = (try? JSONSerialization.jsonObject(with: line("owned_virtual_unattributed_receipt"))) as? [String: Any] ?? [:]
        fields["word"] = String(format: "%08x", evidence.word)
        fields["packet_timestamp"] = String(evidence.timestamp)
        fields["callback_generation"] = String(evidence.generation)
        fields["attribution"] = "unknown"
        fields["ticket"] = NSNull()
        fields["transport_accepted"] = NSNull()
        if let origin = evidence.origin {
            fields["endpoint_origin"] = ["input_id": origin.inputID.map { $0 as Any } ?? NSNull(), "output_id": origin.outputID.map { $0 as Any } ?? NSNull(),
                                         "connection_generation": String(origin.connectionGeneration), "transport_origin": origin.transportOrigin]
        } else {
            fields["endpoint_origin"] = NSNull()
        }
        if let body = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]) {
            FileHandle.standardError.write(body + Data([10]))
        }
    }

    func emit(_ event: String, operation: String? = nil) {
        FileHandle.standardError.write(line(event, operation: operation))
    }
}

/// A permanent disconnected adapter, with no CoreMIDI dependency or scripted input path.
final class DisabledHardwareMIDI: HardwareMIDI {
    private var announced = false
    func drain() throws -> [HardwareMIDIEvent] {
        guard !announced else { return [] }
        announced = true
        return [.link(connected: false)]
    }

    var currentOrigin: HardwareEndpointOrigin {
        .unavailable
    }

    func send(_: HardwareDisplayMessage, expectedOrigin _: HardwareEndpointOrigin) throws {
        throw DeviceAccessDisabledError.outputForbidden
    }

    /// Permanently disconnected: there is no link to re-establish.
    func invalidate() {}

    enum DeviceAccessDisabledError: Error { case outputForbidden }
}
