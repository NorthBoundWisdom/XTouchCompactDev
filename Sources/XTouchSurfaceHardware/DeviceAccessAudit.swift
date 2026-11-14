import Foundation
import SurfaceControlContracts
import XTouchCompactCore

/// Counts actual CoreMIDI call sites, not successful device state or inferred observations.
final class DeviceAccessAudit: @unchecked Sendable {
    private let lock = NSLock()
    let access: HardwareDeviceAccess
    private var counters: [String: Int] = ["coremidi_factory_calls": 0, "scripted_factory_calls": 0,
                                           "client_create_calls": 0, "input_port_create_calls": 0, "output_port_create_calls": 0,
                                           "source_enumeration_calls": 0, "destination_enumeration_calls": 0,
                                           "source_connect_calls": 0, "midi_send_calls": 0, "accepted_messages": 0]
    init(access: HardwareDeviceAccess) {
        self.access = access
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
        if let operation {
            fields["operation"] = operation
        }
        return (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])).map { $0 + Data("\n".utf8) } ?? Data()
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

    func send(_: HardwareDisplayMessage) throws {
        throw DeviceAccessDisabledError.outputForbidden
    }

    enum DeviceAccessDisabledError: Error { case outputForbidden }
}
