import Darwin
import Foundation
import SurfaceControlContracts
import XTouchCompactCore

struct OwnedInputLease: Equatable, Sendable {
    let ticket: UInt64
    let message: MIDIMessage
    let origin: HardwareEndpointOrigin
    let publishedAt: Double
    var receivedAt: Double?
}

struct OwnedRehearsalCompleted: Error {}

struct OwnedReceiptEvidence: Equatable, Sendable {
    let word: UInt32
    let timestamp: UInt64
    let generation: UInt64
    let origin: HardwareEndpointOrigin?
    let ticket: UInt64?
    let transportAccepted: Bool?
}

/// One-time creation evidence retained by the specific destination callback, including
/// callbacks delivered after that endpoint has retired. Never fill from the current route.
private final class OwnedCallbackScope: @unchecked Sendable {
    private let lock = NSLock()
    private var value: HardwareEndpointOrigin?
    func install(_ origin: HardwareEndpointOrigin) {
        lock.lock(); defer { lock.unlock() }
        precondition(value == nil)
        value = origin
    }

    var snapshot: HardwareEndpointOrigin? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

/// One serial owner drains commands and commits/rejects input leases. CoreMIDI callbacks
/// only move already-reserved, bounded tickets; they never enqueue Tasks or mutate surface values.
final class OwnedVirtualHardwareMIDI: HardwareMIDI, @unchecked Sendable {
    static let inputLimit = 4096
    static let receiptLimit = 4096
    static let linkLimit = 2 * OwnedRehearsalSteps.commandLimit + 1
    private let system: any OwnedVirtualMIDISystem
    private let configuration: CompactHardwareConfiguration
    private let audit: DeviceAccessAudit
    private let steps: () throws -> [OwnedRehearsalStep]
    private let clock: @Sendable () -> Double
    private let stamp: @Sendable () -> UInt64
    private var lastStamp: UInt64 = 0
    private let lock = NSLock()
    private var client: UInt32 = 0
    private var input: UInt32 = 0
    private var output: UInt32 = 0
    private var source: UInt32 = 0
    private var destination: UInt32 = 0
    private var origin = HardwareEndpointOrigin(inputID: nil, outputID: nil, connectionGeneration: 0, transportOrigin: "localVirtual")
    private var connected = false
    private var failure: OwnedRehearsalFailure?
    private var startedPeer = false
    private var finishDeadline: Double?
    private var links: [HardwareMIDIEvent] = []
    private var cleanupStarted = false
    private var cleanupUncertain = false
    private var sequence: UInt64 = 0
    private var tickets: [UInt64: OwnedInputLease] = [:]
    private var publications: [UInt64] = []
    private var incoming: [OwnedInputLease] = []
    private var handedOff: Set<UInt64> = []
    private struct Receipt {
        let ticket: UInt64
        let word: UInt32
        let timestamp: UInt64
        let origin: HardwareEndpointOrigin
        var accepted = false
    }

    private var displayTickets: [UInt64: Receipt] = [:]
    private var displayAwaiting: [UInt64] = []
    private var receipts: [UInt64] = []
    private var unattributed: [OwnedReceiptEvidence] = []

    var currentOrigin: HardwareEndpointOrigin {
        lock.lock(); defer { lock.unlock() }; return origin
    }

    var outstandingInputCount: Int {
        lock.lock(); defer { lock.unlock() }; return tickets.count
    }

    init(system: any OwnedVirtualMIDISystem, configuration: CompactHardwareConfiguration, audit: DeviceAccessAudit,
         steps: @escaping () throws -> [OwnedRehearsalStep], clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }, stamp: @escaping @Sendable () -> UInt64 = { mach_absolute_time() }) throws
    {
        self.system = system; self.configuration = configuration; self.audit = audit; self.steps = steps; self.clock = clock; self.stamp = stamp
        client = try system.client { [weak self] ref in self?.removed(ref) }
        do {
            let inputRef = try system.input(client: client) { [weak self] result, generation in self?.received(result, generation: generation) }
            lock.lock(); input = inputRef; lock.unlock()
            let outputRef = try system.output(client: client)
            lock.lock(); output = outputRef; lock.unlock()
            try establish()
        } catch {
            do { try cleanup() } catch { throw OwnedRehearsalFailure.cleanup }
            throw error
        }
    }

    func startPeer() throws {
        lock.lock(); defer { lock.unlock() }
        guard !cleanupStarted else { throw OwnedRehearsalFailure.terminal }
        if let failure {
            throw failure
        }
        startedPeer = true
    }

    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }; return connected && failure == nil && !cleanupStarted
    }

    var outstandingDisplayCount: Int {
        lock.lock(); defer { lock.unlock() }; return displayTickets.count
    }

    private func nextTicketLocked() throws -> UInt64 {
        guard sequence < UInt64.max else { throw OwnedRehearsalFailure.transport }
        sequence += 1; return sequence
    }

    private func faultLocked(_ error: OwnedRehearsalFailure) {
        if failure == nil {
            failure = error; audit.increment("owned_faults")
        }
        connected = false
        // Do not free a single ticket here: ownership lasts through final owner rejection.
    }

    private func removed(_ ref: UInt32) {
        lock.lock(); defer { lock.unlock() }
        guard ref != 0, ref == source || ref == destination || ref == input || ref == output else {
            audit.increment("owned_unrelated_notifications_ignored"); return
        }
        faultLocked(.endpointOwnership)
    }

    private func establish() throws {
        lock.lock()
        guard !cleanupStarted else { lock.unlock(); throw OwnedRehearsalFailure.terminal }
        guard origin.connectionGeneration < UInt64.max else { lock.unlock(); throw OwnedRehearsalFailure.transport }
        let generation = origin.connectionGeneration + 1
        lock.unlock()
        let newSource = try system.source(client: client)
        let newDestination: UInt32
        let callbackScope = OwnedCallbackScope()
        do {
            newDestination = try system.destination(client: client) { [weak self] result in self?.receivedDisplay(result, generation: generation, captured: callbackScope.snapshot) }
        } catch {
            do { try system.disposeEndpoint(newSource) } catch { cleanupUncertain = true; throw OwnedRehearsalFailure.cleanup }
            throw error
        }
        let inputID: Int32, outputID: Int32
        do { inputID = try system.identity(newSource); outputID = try system.identity(newDestination) }
        catch {
            var failed = false
            do { try system.disposeEndpoint(newSource) } catch { failed = true }
            do { try system.disposeEndpoint(newDestination) } catch { failed = true }
            if failed {
                cleanupUncertain = true; throw OwnedRehearsalFailure.cleanup
            }
            throw error
        }
        let next = HardwareEndpointOrigin(inputID: inputID, outputID: outputID, connectionGeneration: generation, transportOrigin: "localVirtual")
        callbackScope.install(next)
        lock.lock(); source = newSource; destination = newDestination; origin = next; lock.unlock()
        do { try system.connect(input: input, source: newSource, generation: generation) }
        catch {
            do { try closeEndpoints() } catch { throw OwnedRehearsalFailure.cleanup }
            throw error
        }
        lock.lock()
        if let failure {
            lock.unlock(); throw failure
        }
        guard links.count < Self.linkLimit else { faultLocked(.bufferOverflow); lock.unlock(); throw OwnedRehearsalFailure.bufferOverflow }
        connected = true; links.append(.link(connected: true, origin: next)); lock.unlock()
        audit.emitOwned("owned_virtual_connected", origin: next)
    }

    private func validateOwnedEndpoints() throws {
        lock.lock(); let src = source, dst = destination, captured = origin; let terminal = cleanupStarted
        let allowed = connected && failure == nil; lock.unlock()
        guard !terminal else { throw OwnedRehearsalFailure.terminal }
        guard allowed, src != 0, dst != 0 else { throw OwnedRehearsalFailure.endpointOwnership }
        do {
            guard try system.identity(src) == captured.inputID, try system.identity(dst) == captured.outputID else {
                throw OwnedRehearsalFailure.endpointOwnership
            }
        } catch {
            lock.lock(); faultLocked(.endpointOwnership); lock.unlock()
            throw OwnedRehearsalFailure.endpointOwnership
        }
    }

    private func publish(_ message: MIDIMessage, generation: UInt64) throws {
        try validateOwnedEndpoints()
        switch message {
        case let .controlChange(channel, number, value), let .noteOn(channel, number, value), let .noteOff(channel, number, value):
            guard channel < 16, number < 128, value < 128 else { throw OwnedRehearsalFailure.invalidFrame }
        default: throw OwnedRehearsalFailure.invalidFrame
        }
        let now = clock()
        guard now.isFinite else { throw OwnedRehearsalFailure.invalidFrame }
        lock.lock()
        guard !cleanupStarted, connected, failure == nil, generation == origin.connectionGeneration else { lock.unlock(); throw OwnedRehearsalFailure.staleGeneration }
        guard tickets.count < Self.inputLimit else { faultLocked(.inputOverflow); lock.unlock(); throw OwnedRehearsalFailure.inputOverflow }
        let ticket: UInt64
        do { ticket = try nextTicketLocked() }
        catch { faultLocked(.transport); lock.unlock(); throw error }
        let lease = OwnedInputLease(ticket: ticket, message: message, origin: origin, publishedAt: now)
        tickets[ticket] = lease; publications.append(ticket)
        let src = source
        lock.unlock()
        // Reservation precedes the CoreMIDI hop, not merely the callback's queue append.
        do { try system.publish(source: src, word: MIDI1UMPCodec.encode(message)) }
        catch { lock.lock(); faultLocked(.transport); lock.unlock(); throw error }
    }

    private func received(_ result: Result<[UInt32], OwnedRehearsalFailure>, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard !cleanupStarted, connected, failure == nil, generation == origin.connectionGeneration else { audit.increment("owned_stale_input_callbacks"); return }
        guard case let .success(words) = result, words.count <= Self.inputLimit else { faultLocked(.inputOverflow); return }
        for word in words {
            guard let ticket = publications.first, var lease = tickets[ticket],
                  lease.origin == origin, word == MIDI1UMPCodec.encode(lease.message) else { faultLocked(.unexpectedInput); return }
            guard incoming.count < Self.inputLimit else { faultLocked(.inputOverflow); return }
            let now = clock()
            guard now.isFinite, now >= lease.publishedAt else { faultLocked(.unexpectedInput); return }
            publications.removeFirst(); lease.receivedAt = now; tickets[ticket] = lease; incoming.append(lease)
            audit.increment("owned_input_callbacks")
        }
    }

    /// The last generation check and canonical assignment are atomic with respect to callbacks.
    func commit(_ lease: OwnedInputLease, accepted: Bool, _ canonicalCommit: () -> Void) throws {
        try validateOwnedEndpoints()
        lock.lock(); defer { lock.unlock() }
        guard !cleanupStarted, failure == nil, connected, lease.origin == origin, handedOff.contains(lease.ticket), tickets[lease.ticket] == lease else {
            rejectLocked(lease.ticket); throw OwnedRehearsalFailure.staleGeneration
        }
        canonicalCommit()
        tickets.removeValue(forKey: lease.ticket); handedOff.remove(lease.ticket)
        audit.increment(accepted ? "owned_input_owner_accepted" : "owned_input_owner_rejected")
    }

    func commitFeedback(expectedOrigin: HardwareEndpointOrigin, _ canonicalCommit: () -> Void) throws {
        try validateOwnedEndpoints()
        lock.lock(); defer { lock.unlock() }
        guard !cleanupStarted, connected, failure == nil, origin == expectedOrigin else { throw OwnedRehearsalFailure.staleGeneration }
        canonicalCommit()
    }

    private func rejectLocked(_ ticket: UInt64) {
        if tickets.removeValue(forKey: ticket) != nil {
            audit.increment("owned_input_owner_rejected")
        }
        handedOff.remove(ticket)
    }

    func reject(_ lease: OwnedInputLease) {
        lock.lock(); rejectLocked(lease.ticket); lock.unlock()
    }

    private func receivedDisplay(_ result: Result<[OwnedDisplayWord], OwnedRehearsalFailure>, generation: UInt64, captured: HardwareEndpointOrigin?) {
        lock.lock(); defer { lock.unlock() }
        guard !cleanupStarted else { audit.increment("owned_post_cleanup_receipts_ignored"); return }
        guard case let .success(words) = result, words.count <= Self.receiptLimit else { faultLocked(.receiptOverflow); return }
        for packet in words {
            guard receipts.count + unattributed.count < Self.receiptLimit else { faultLocked(.receiptOverflow); return }
            let match = connected && failure == nil && generation == origin.connectionGeneration && captured == origin
                ? displayAwaiting.firstIndex(where: { ticket in
                    guard let expected = displayTickets[ticket] else { return false }
                    return packet.timestamp != 0 && expected.timestamp == packet.timestamp && expected.word == packet.word && expected.origin == captured
                }) : nil
            if let match {
                receipts.append(displayAwaiting.remove(at: match))
            } else {
                audit.increment("owned_unattributed_display_receipts")
                unattributed.append(.init(word: packet.word, timestamp: packet.timestamp, generation: generation,
                                          origin: captured, ticket: nil, transportAccepted: nil))
            }
        }
    }

    func send(_ message: HardwareDisplayMessage, expectedOrigin: HardwareEndpointOrigin) throws {
        try validateOwnedEndpoints()
        let word = try message.word(configuration: configuration)
        lock.lock()
        guard !cleanupStarted, connected, failure == nil, expectedOrigin == origin else { lock.unlock(); throw ControlContractError("invalid_transition") }
        guard displayTickets.count < Self.receiptLimit else { faultLocked(.receiptOverflow); lock.unlock(); throw OwnedRehearsalFailure.receiptOverflow }
        let ticket: UInt64
        do { ticket = try nextTicketLocked() }
        catch { faultLocked(.transport); lock.unlock(); throw error }
        let nowStamp = stamp()
        guard nowStamp != 0, lastStamp < UInt64.max else { faultLocked(.transport); lock.unlock(); throw OwnedRehearsalFailure.transport }
        let timestamp = max(nowStamp, lastStamp + 1)
        lastStamp = timestamp
        let captured = origin, dst = destination
        displayTickets[ticket] = .init(ticket: ticket, word: word, timestamp: timestamp, origin: captured); displayAwaiting.append(ticket)
        lock.unlock()
        do { try system.display(message, configuration: configuration, output: output, destination: dst, timestamp: timestamp) }
        catch { lock.lock(); faultLocked(.transport); lock.unlock(); throw error }
        audit.emitOwned("owned_virtual_send_accepted", origin: captured, word: word, ticket: ticket, packetTimestamp: timestamp)
        lock.lock(); displayTickets[ticket]?.accepted = true
        let stillCurrent = failure == nil && connected && origin == captured
        lock.unlock()
        guard stillCurrent else { throw OwnedRehearsalFailure.staleGeneration }
    }

    /// Serial-owner consumption only. Unknown receipts carry actual callback evidence,
    /// never an own ticket or an inferred accepted-send result.
    func takeReceiptEvidence() -> [OwnedReceiptEvidence] {
        lock.lock(); defer { lock.unlock() }
        let matched = receipts.compactMap { displayTickets.removeValue(forKey: $0) }.map {
            OwnedReceiptEvidence(word: $0.word, timestamp: $0.timestamp, generation: $0.origin.connectionGeneration,
                                 origin: $0.origin, ticket: $0.ticket, transportAccepted: $0.accepted)
        }
        receipts.removeAll(keepingCapacity: true)
        let unknown = unattributed; unattributed.removeAll(keepingCapacity: true)
        return matched + unknown
    }

    private func drainReceipts() {
        for evidence in takeReceiptEvidence() {
            if let ticket = evidence.ticket, let origin = evidence.origin {
                audit.emitOwned("owned_virtual_display_receipt", origin: origin, word: evidence.word, ticket: ticket,
                                accepted: evidence.transportAccepted, packetTimestamp: evidence.timestamp)
            } else {
                audit.emitUnattributed(evidence)
            }
        }
    }

    func drain() throws -> [HardwareMIDIEvent] {
        lock.lock(); let terminal = cleanupStarted; let currentFailure = failure; let checkUID = connected; lock.unlock()
        guard !terminal else { throw OwnedRehearsalFailure.terminal }
        if checkUID {
            try validateOwnedEndpoints()
        }
        if let currentFailure {
            throw currentFailure
        }
        drainReceipts()
        if startedPeer, finishDeadline == nil {
            let commands = try steps()
            guard commands.count <= OwnedRehearsalSteps.commandLimit else { throw OwnedRehearsalFailure.bufferOverflow }
            for (index, command) in commands.enumerated() {
                switch command {
                case let .input(message, generation): try publish(message, generation: generation)
                case .disconnect: try closeEndpoints()
                case .reconnect: try closeEndpoints(); try establish()
                case .finish:
                    guard index == commands.count - 1 else { throw OwnedRehearsalFailure.invalidFrame }
                    finishDeadline = clock() + 2
                }
            }
        }
        lock.lock()
        let failed = failure
        let result = links + incoming.map(HardwareMIDIEvent.ownedInput)
        links.removeAll(keepingCapacity: true)
        handedOff.formUnion(incoming.map(\.ticket)); incoming.removeAll(keepingCapacity: true)
        let empty = tickets.isEmpty && displayTickets.isEmpty
        lock.unlock()
        if let failed {
            throw failed
        }
        if let deadline = finishDeadline {
            if empty {
                try cleanup(); throw OwnedRehearsalCompleted()
            }
            if clock() >= deadline {
                throw OwnedRehearsalFailure.finishTimeout
            }
        }
        return result
    }

    private func closeEndpoints() throws {
        lock.lock()
        let src = source, dst = destination
        source = 0; destination = 0; connected = false
        for ticket in Array(tickets.keys) {
            rejectLocked(ticket)
        }
        publications.removeAll(); incoming.removeAll(); handedOff.removeAll()
        displayTickets.removeAll(); displayAwaiting.removeAll(); receipts.removeAll(); unattributed.removeAll()
        guard origin.connectionGeneration < UInt64.max else { lock.unlock(); throw OwnedRehearsalFailure.transport }
        origin = .init(inputID: nil, outputID: nil, connectionGeneration: origin.connectionGeneration + 1, transportOrigin: "localVirtual")
        let closed = origin
        if links.count < Self.linkLimit {
            links.append(.link(connected: false, origin: closed))
        } else {
            faultLocked(.bufferOverflow)
        }
        lock.unlock()
        var failed = false
        if src != 0 {
            do { try system.disconnect(input: input, source: src) } catch { failed = true }
            do { try system.disposeEndpoint(src) } catch { failed = true }
        }
        if dst != 0 {
            do { try system.disposeEndpoint(dst) } catch { failed = true }
        }
        audit.emitOwned("owned_virtual_disconnected", origin: closed)
        if failed {
            cleanupUncertain = true; throw OwnedRehearsalFailure.cleanup
        }
    }

    /// Called only by the serial owner on finish/error; never from a CoreMIDI callback/signal.
    func cleanup() throws {
        lock.lock()
        if cleanupStarted {
            let uncertain = cleanupUncertain
            lock.unlock()
            if uncertain {
                throw OwnedRehearsalFailure.cleanup
            }
            return
        }
        cleanupStarted = true
        lock.unlock()
        var failed = cleanupUncertain
        do { try closeEndpoints() } catch { failed = true }
        lock.lock(); let ports = [input, output]; input = 0; output = 0; lock.unlock()
        for port in ports where port != 0 {
            do { try system.disposePort(port) } catch { failed = true }
        }
        audit.emitOwned(failed ? "owned_virtual_cleanup_failed" : "owned_virtual_cleanup_complete", origin: currentOrigin)
        // The one client survives reconnect and is disposed by CoreMIDI at process exit.
        cleanupUncertain = failed
        if failed {
            throw OwnedRehearsalFailure.cleanup
        }
    }

    /// No automatic retry or physical fallback. Only an explicit private reconnect can create endpoints.
    func invalidate() {}
}
