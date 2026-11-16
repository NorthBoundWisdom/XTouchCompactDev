import CoreMIDI
import Foundation
import XTouchCompactCore

/// Only creation-returned references can be retained by the owned transport. This seam
/// deliberately offers no global discovery, name lookup or ordinary-device factory.
protocol OwnedVirtualMIDISystem: AnyObject {
    func client(removed: @escaping @Sendable (UInt32) -> Void) throws -> UInt32
    func source(client: UInt32) throws -> UInt32
    func destination(client: UInt32, receive: @escaping @Sendable (Result<[UInt32], OwnedRehearsalFailure>) -> Void) throws -> UInt32
    func input(client: UInt32, receive: @escaping @Sendable (Result<[UInt32], OwnedRehearsalFailure>, UInt64) -> Void) throws -> UInt32
    func output(client: UInt32) throws -> UInt32
    func identity(_ endpoint: UInt32) throws -> Int32
    func connect(input: UInt32, source: UInt32, generation: UInt64) throws
    func disconnect(input: UInt32, source: UInt32) throws
    func publish(source: UInt32, word: UInt32) throws
    func display(_ message: HardwareDisplayMessage, configuration: CompactHardwareConfiguration, output: UInt32, destination: UInt32) throws
    func disposeEndpoint(_ endpoint: UInt32) throws
    func disposePort(_ port: UInt32) throws
}

final class CoreMIDIOwnedSystem: OwnedVirtualMIDISystem {
    private let audit: DeviceAccessAudit
    init(audit: DeviceAccessAudit) {
        self.audit = audit
    }

    func client(removed: @escaping @Sendable (UInt32) -> Void) throws -> UInt32 {
        var result: MIDIClientRef = 0
        audit.increment("client_create_calls")
        let status = MIDIClientCreateWithBlock("Compact owned rehearsal" as CFString, &result) { notice in
            guard notice.pointee.messageID == .msgObjectRemoved,
                  notice.pointee.messageSize >= UInt32(MemoryLayout<MIDIObjectAddRemoveNotification>.size) else { return }
            let change = UnsafeRawPointer(notice).assumingMemoryBound(to: MIDIObjectAddRemoveNotification.self).pointee
            removed(change.child)
        }
        guard status == noErr else { throw OwnedRehearsalFailure.transport }
        return result
    }

    func source(client: UInt32) throws -> UInt32 {
        var result: MIDIEndpointRef = 0
        audit.increment("owned_source_create_calls")
        guard MIDISourceCreateWithProtocol(client, "Compact owned input" as CFString, ._1_0, &result) == noErr else { throw OwnedRehearsalFailure.transport }
        return result
    }

    func destination(client: UInt32, receive: @escaping @Sendable (Result<[UInt32], OwnedRehearsalFailure>) -> Void) throws -> UInt32 {
        var result: MIDIEndpointRef = 0
        audit.increment("owned_destination_create_calls")
        guard MIDIDestinationCreateWithProtocol(client, "Compact owned display" as CFString, ._1_0, &result, { list, _ in
            receive(Self.boundedWords(list))
        }) == noErr else { throw OwnedRehearsalFailure.transport }
        return result
    }

    func input(client: UInt32, receive: @escaping @Sendable (Result<[UInt32], OwnedRehearsalFailure>, UInt64) -> Void) throws -> UInt32 {
        var result: MIDIPortRef = 0
        audit.increment("input_port_create_calls")
        guard MIDIInputPortCreateWithProtocol(client, "Owned input port" as CFString, ._1_0, &result, { list, tag in
            receive(Self.boundedWords(list), UInt64(UInt(bitPattern: tag)))
        }) == noErr else { throw OwnedRehearsalFailure.transport }
        return result
    }

    func output(client: UInt32) throws -> UInt32 {
        var result: MIDIPortRef = 0
        audit.increment("output_port_create_calls")
        guard MIDIOutputPortCreate(client, "Owned display port" as CFString, &result) == noErr else { throw OwnedRehearsalFailure.transport }
        return result
    }

    func identity(_ endpoint: UInt32) throws -> Int32 {
        var value: Int32 = 0
        guard endpoint != 0, MIDIObjectGetIntegerProperty(endpoint, kMIDIPropertyUniqueID, &value) == noErr, value != 0 else { throw OwnedRehearsalFailure.endpointOwnership }
        return value
    }

    func connect(input: UInt32, source: UInt32, generation: UInt64) throws {
        audit.increment("source_connect_calls")
        guard MIDIPortConnectSource(input, source, UnsafeMutableRawPointer(bitPattern: UInt(generation))) == noErr else { throw OwnedRehearsalFailure.transport }
    }

    func disconnect(input: UInt32, source: UInt32) throws {
        audit.increment("owned_source_disconnect_calls")
        guard MIDIPortDisconnectSource(input, source) == noErr else { throw OwnedRehearsalFailure.cleanup }
    }

    private static func eventList(_ word: UInt32, send: (UnsafePointer<MIDIEventList>) -> OSStatus) throws {
        var word = word
        var list = MIDIEventList()
        let first = MIDIEventListInit(&list, ._1_0)
        _ = MIDIEventListAdd(&list, MemoryLayout<MIDIEventList>.size, first, 0, 1, &word)
        guard send(&list) == noErr else { throw OwnedRehearsalFailure.transport }
    }

    func publish(source: UInt32, word: UInt32) throws {
        audit.increment("owned_input_publish_calls")
        try Self.eventList(word) { MIDIReceivedEventList(source, $0) }
    }

    func display(_ message: HardwareDisplayMessage, configuration: CompactHardwareConfiguration, output: UInt32, destination: UInt32) throws {
        let word = try message.word(configuration: configuration)
        audit.increment("midi_send_calls")
        try Self.eventList(word) { MIDISendEventList(output, destination, $0) }
        audit.increment("accepted_messages")
    }

    func disposeEndpoint(_ endpoint: UInt32) throws {
        audit.increment("owned_endpoint_dispose_calls")
        guard MIDIEndpointDispose(endpoint) == noErr else { throw OwnedRehearsalFailure.cleanup }
    }

    func disposePort(_ port: UInt32) throws {
        audit.increment("owned_port_dispose_calls")
        guard MIDIPortDispose(port) == noErr else { throw OwnedRehearsalFailure.cleanup }
    }

    /// Bound decoding before allocation or handoff; there is no async/Task hop here.
    static func boundedWords(_ list: UnsafePointer<MIDIEventList>) -> Result<[UInt32], OwnedRehearsalFailure> {
        guard list.pointee.numPackets <= 64,
              let offset = MemoryLayout<MIDIEventList>.offset(of: \.packet),
              let wordsOffset = MemoryLayout<MIDIEventPacket>.offset(of: \.words) else { return .failure(.inputOverflow) }
        var result: [UInt32] = []
        var packet = UnsafeRawPointer(list).advanced(by: offset).assumingMemoryBound(to: MIDIEventPacket.self)
        for _ in 0 ..< list.pointee.numPackets {
            let count = Int(packet.pointee.wordCount)
            guard count <= 64, count <= 4096 - result.count else { return .failure(.inputOverflow) }
            let words = UnsafeRawPointer(packet).advanced(by: wordsOffset).assumingMemoryBound(to: UInt32.self)
            for index in 0 ..< count {
                result.append(words[index])
            }
            packet = UnsafePointer(MIDIEventPacketNext(packet))
        }
        return .success(result)
    }
}
