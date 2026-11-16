import CoreMIDI
import Foundation
import SurfaceControlContracts
import XTouchCompactCore

struct HardwareEndpointOrigin: Equatable, Sendable {
    var inputID: Int32?
    var outputID: Int32?
    var connectionGeneration: UInt64
    var transportOrigin: String
    static let unavailable = HardwareEndpointOrigin(inputID: nil, outputID: nil, connectionGeneration: 0, transportOrigin: "unknown")
}

enum HardwareMIDIEvent {
    case link(connected: Bool, origin: HardwareEndpointOrigin = .unavailable)
    case message(MIDIMessage, origin: HardwareEndpointOrigin)
    case undecoded(origin: HardwareEndpointOrigin)
}

/// Only typed display requests can cross this boundary. No API accepts raw MIDI for output.
protocol HardwareMIDI: AnyObject {
    func drain() throws -> [HardwareMIDIEvent]
    var currentOrigin: HardwareEndpointOrigin { get }
    func send(_ message: HardwareDisplayMessage, expectedOrigin: HardwareEndpointOrigin) throws
    /// Forget the current link so the next drain re-establishes it and reports a link event.
    func invalidate()
}

final class CoreHardwareMIDI: HardwareMIDI, @unchecked Sendable {
    private var client: MIDIClientRef = 0
    private var input: MIDIPortRef = 0
    private var output: MIDIPortRef = 0
    private var source: MIDIEndpointRef = 0
    private var destination: MIDIEndpointRef = 0
    private let configuration: CompactHardwareConfiguration
    private let deviceName: String
    private let audit: DeviceAccessAudit
    private let lock = NSLock()
    private var pending: [HardwareMIDIEvent] = []
    private var overflow = false
    private var initialized = false
    private var seenSource: MIDIEndpointRef = 0
    private var seenDestination: MIDIEndpointRef = 0
    private var origin = HardwareEndpointOrigin.unavailable
    var currentOrigin: HardwareEndpointOrigin {
        lock.lock(); defer { lock.unlock() }; return origin
    }

    private func identity(_ endpoint: MIDIEndpointRef) -> Int32? {
        var id: Int32 = 0
        guard endpoint != 0, MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &id) == noErr else { return nil }
        return id
    }

    init(deviceName: String, configuration: CompactHardwareConfiguration, audit: DeviceAccessAudit) throws {
        self.audit = audit
        self.configuration = configuration
        self.deviceName = deviceName
        audit.increment("client_create_calls")
        guard MIDIClientCreateWithBlock("XTouchSurfaceHardware" as CFString, &client, { _ in }) == noErr else { throw ControlContractError("transport_error") }
        audit.increment("input_port_create_calls")
        guard MIDIInputPortCreateWithProtocol(client, "Hardware input" as CFString, ._1_0, &input, { [weak self] list, tag in
            guard let self else { return }
            lock.lock(); defer { lock.unlock() }
            guard source != 0, origin.connectionGeneration == UInt64(UInt(bitPattern: tag)), let packetOffset = MemoryLayout<MIDIEventList>.offset(of: \.packet), let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words) else { return }
            var packet = UnsafeRawPointer(list).advanced(by: packetOffset).assumingMemoryBound(to: MIDIEventPacket.self)
            for _ in 0 ..< list.pointee.numPackets {
                guard packet.pointee.wordCount <= 64, pending.count + Int(packet.pointee.wordCount) <= 4096 else { overflow = true; return }
                let words = UnsafeRawPointer(packet).advanced(by: wordsOffset).assumingMemoryBound(to: UInt32.self)
                for index in 0 ..< Int(packet.pointee.wordCount) {
                    if let message = Self.decode(words[index]) {
                        pending.append(.message(message, origin: origin))
                    } else {
                        pending.append(.undecoded(origin: origin))
                    }
                }
                packet = UnsafePointer(MIDIEventPacketNext(packet))
            }
        }) == noErr else { throw ControlContractError("transport_error") }
        audit.increment("output_port_create_calls")
        guard MIDIOutputPortCreate(client, "Display only" as CFString, &output) == noErr else { throw ControlContractError("transport_error") }
    }

    deinit {
        if client != 0 {
            MIDIClientDispose(client)
        }
    }

    private static func decode(_ word: UInt32) -> MIDIMessage? {
        guard word >> 28 == 2 else { return nil }
        let status = UInt8((word >> 16) & 0xFF), number = UInt8((word >> 8) & 0xFF), value = UInt8(word & 0xFF)
        guard number < 128, value < 128 else { return nil }
        switch status & 0xF0 {
        case 0xB0: return .controlChange(channel: status & 15, number: number, value: value)
        case 0x90: return .noteOn(channel: status & 15, number: number, velocity: value)
        case 0x80: return .noteOff(channel: status & 15, number: number, velocity: value)
        default: return nil
        }
    }

    private func find(_ count: Int, at: (Int) -> MIDIEndpointRef) -> MIDIEndpointRef {
        let candidates = (0 ..< count).map(at).filter { endpoint in
            var name: Unmanaged<CFString>?, offline: Int32 = 0
            _ = MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyOffline, &offline)
            guard offline == 0, MIDIObjectGetStringProperty(endpoint, kMIDIPropertyDisplayName, &name) == noErr, let name else { return false }
            return (name.takeRetainedValue() as String).localizedCaseInsensitiveContains(deviceName)
        }
        // Ambiguous endpoint selection fails closed, rather than connecting to an arbitrary port.
        return candidates.count == 1 ? candidates[0] : 0
    }

    private func endpoints() -> (MIDIEndpointRef, MIDIEndpointRef) {
        audit.increment("source_enumeration_calls")
        let source = find(MIDIGetNumberOfSources(), at: MIDIGetSource)
        audit.increment("destination_enumeration_calls")
        let destination = find(MIDIGetNumberOfDestinations(), at: MIDIGetDestination)
        return (source, destination)
    }

    func invalidate() {
        lock.lock(); initialized = false; lock.unlock()
    }

    func drain() throws -> [HardwareMIDIEvent] {
        let (newSource, newDestination) = endpoints()
        lock.lock()
        let oldSource = source
        let changed = !initialized || newSource != seenSource || newDestination != seenDestination || overflow
        if changed {
            pending = []; source = 0; destination = 0; overflow = false; initialized = true
            origin = .init(inputID: nil, outputID: nil, connectionGeneration: origin.connectionGeneration &+ 1, transportOrigin: "unknown")
            seenSource = newSource; seenDestination = newDestination
        }
        lock.unlock()
        if changed {
            if oldSource != 0 {
                MIDIPortDisconnectSource(input, oldSource)
            }
            var connected = false
            if newSource != 0, newDestination != 0 {
                audit.increment("source_connect_calls")
                connected = MIDIPortConnectSource(input, newSource, UnsafeMutableRawPointer(bitPattern: UInt(currentOrigin.connectionGeneration))) == noErr
            }
            lock.lock()
            source = connected ? newSource : 0; destination = connected ? newDestination : 0
            origin.inputID = identity(source); origin.outputID = identity(destination)
            pending.insert(.link(connected: connected, origin: origin), at: 0)
            lock.unlock()
        }
        lock.lock(); defer { lock.unlock() }
        let result = pending; pending = []
        return result
    }

    func send(_ message: HardwareDisplayMessage, expectedOrigin: HardwareEndpointOrigin) throws {
        // Refresh endpoint identity immediately before sending. A transition invalidates the caller's pin.
        let (newSource, newDestination) = endpoints()
        lock.lock(); let current = destination; let same = source != 0 && source == newSource && destination == newDestination && origin == expectedOrigin; lock.unlock()
        guard same, current != 0 else { throw ControlContractError("invalid_transition") }
        var word = try message.word(configuration: configuration)
        var list = MIDIEventList()
        let first = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, first, 0, 1, &word)
        audit.increment("midi_send_calls")
        guard MIDISendEventList(output, current, &list) == noErr else { throw ControlContractError("transport_error") }
        audit.increment("accepted_messages")
    }
}

#if DEBUG
    /// Test-only local file adapter (Debug builds only). No public RPC can create hardware input or
    /// change this script. The production adapter is never initialized when it is selected.
    final class ScriptedHardwareMIDI: HardwareMIDI {
        private let path: String
        private let report: String?
        private let configuration: CompactHardwareConfiguration
        private var consumed = 0
        private var words: [String] = []
        private let timing: FileHandle?
        private var failSend = false
        private var connected = false
        private var relink = false
        private var origin = HardwareEndpointOrigin(inputID: 1, outputID: 1, connectionGeneration: 1, transportOrigin: "localVirtual")
        var currentOrigin: HardwareEndpointOrigin {
            origin
        }

        init(path: String, report: String?, timingPath: String?, configuration: CompactHardwareConfiguration) throws {
            self.path = path; self.report = report; self.configuration = configuration
            if let timingPath {
                let url = URL(fileURLWithPath: timingPath)
                try Data().write(to: url, options: .withoutOverwriting)
                timing = try FileHandle(forWritingTo: url)
            } else {
                timing = nil
            }
        }

        func drain() throws -> [HardwareMIDIEvent] {
            let rows = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path))) as? [[String: Any]] ?? []
            guard rows.count >= consumed else { throw ControlContractError("invalid_transition") }
            var result: [HardwareMIDIEvent] = relink ? [.link(connected: connected, origin: origin)] : []
            relink = false
            for row in rows.dropFirst(consumed) {
                if let connected = row["connected"] as? Bool {
                    self.connected = connected
                    origin.connectionGeneration &+= 1
                    result.append(.link(connected: connected, origin: origin))
                }
                if let failure = row["fail_send"] as? Bool {
                    failSend = failure
                }
                if connected, let bytes = row["bytes"] as? [UInt8], bytes.count == 3, bytes[1] < 128, bytes[2] < 128 {
                    switch bytes[0] & 0xF0 {
                    case 0xB0: result.append(.message(.controlChange(channel: bytes[0] & 15, number: bytes[1], value: bytes[2]), origin: origin))
                    case 0x90: result.append(.message(.noteOn(channel: bytes[0] & 15, number: bytes[1], velocity: bytes[2]), origin: origin))
                    case 0x80: result.append(.message(.noteOff(channel: bytes[0] & 15, number: bytes[1], velocity: bytes[2]), origin: origin))
                    default: result.append(.undecoded(origin: origin))
                    }
                }
            }
            consumed = rows.count
            try writeReport()
            return result
        }

        func invalidate() {
            origin.connectionGeneration &+= 1
            relink = true
        }

        func send(_ message: HardwareDisplayMessage, expectedOrigin: HardwareEndpointOrigin) throws {
            guard expectedOrigin == origin else { throw ControlContractError("invalid_transition") }
            guard !failSend else { throw ControlContractError("transport_error") }
            try words.append(String(format: "%08X", message.word(configuration: configuration)))
            if let timing {
                // Debug-only local transport receipt, not an observation or physical acknowledgement.
                let kind: String, index: Int
                switch message {
                case let .buttonLight(button, _): kind = "indicator"; index = button
                case let .ringDisplay(encoder, _): kind = "value"; index = encoder
                case let .ringStyle(encoder, _): kind = "style"; index = encoder
                }
                let record: [String: Any] = ["event": "test-only-display-received", "server_time": ProcessInfo.processInfo.systemUptime,
                                             "kind": kind, "index": index,
                                             "send_index": words.count, "word": words.last!]
                try timing.write(contentsOf: JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]) + Data("\n".utf8))
            }
            try writeReport()
        }

        private func writeReport() throws {
            if let report {
                let data = try JSONSerialization.data(withJSONObject: ["artifact": "test-only-midi", "words": words, "sent_count": words.count, "moves_motors": 0], options: [.sortedKeys])
                try data.write(to: URL(fileURLWithPath: report), options: .atomic)
            }
        }
    }
#endif
