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
        let origin: HardwareEndpointOrigin
        var accepted = false
    }

    private var displayTickets: [UInt64: Receipt] = [:]
    private var displayAwaiting: [UInt64] = []
    private var receipts: [UInt64] = []

    var currentOrigin: HardwareEndpointOrigin {
        lock.lock(); defer { lock.unlock() }; return origin
    }

    var outstandingInputCount: Int {
        lock.lock(); defer { lock.unlock() }; return tickets.count
    }

    init(system: any OwnedVirtualMIDISystem, configuration: CompactHardwareConfiguration, audit: DeviceAccessAudit,
         steps: @escaping () throws -> [OwnedRehearsalStep], clock: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime }) throws
    {
        self.system = system; self.configuration = configuration; self.audit = audit; self.steps = steps; self.clock = clock
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

    func startPeer() {
        startedPeer = true
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
        guard origin.connectionGeneration < UInt64.max else { lock.unlock(); throw OwnedRehearsalFailure.transport }
        let generation = origin.connectionGeneration + 1
        lock.unlock()
        let newSource = try system.source(client: client)
        let newDestination: UInt32
        do {
            newDestination = try system.destination(client: client) { [weak self] result in self?.receivedDisplay(result, generation: generation) }
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
        lock.lock(); let src = source, dst = destination, captured = origin; let allowed = connected && failure == nil; lock.unlock()
        guard allowed, src != 0, dst != 0,
              try system.identity(src) == captured.inputID, try system.identity(dst) == captured.outputID else { throw OwnedRehearsalFailure.endpointOwnership }
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
        guard connected, failure == nil, generation == origin.connectionGeneration else { lock.unlock(); throw OwnedRehearsalFailure.staleGeneration }
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
        guard connected, failure == nil, generation == origin.connectionGeneration else { audit.increment("owned_stale_input_callbacks"); return }
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
        guard failure == nil, connected, lease.origin == origin, handedOff.contains(lease.ticket), tickets[lease.ticket] == lease else {
            rejectLocked(lease.ticket); throw OwnedRehearsalFailure.staleGeneration
        }
        canonicalCommit()
        tickets.removeValue(forKey: lease.ticket); handedOff.remove(lease.ticket)
        audit.increment(accepted ? "owned_input_owner_accepted" : "owned_input_owner_rejected")
    }

    func commitFeedback(expectedOrigin: HardwareEndpointOrigin, _ canonicalCommit: () -> Void) throws {
        try validateOwnedEndpoints()
        lock.lock(); defer { lock.unlock() }
        guard connected, failure == nil, origin == expectedOrigin else { throw OwnedRehearsalFailure.staleGeneration }
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

    private func receivedDisplay(_ result: Result<[UInt32], OwnedRehearsalFailure>, generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard connected, failure == nil, generation == origin.connectionGeneration else { audit.increment("owned_stale_display_callbacks"); return }
        guard case let .success(words) = result, words.count <= Self.receiptLimit else { faultLocked(.receiptOverflow); return }
        for word in words {
            guard let ticket = displayAwaiting.first, let expected = displayTickets[ticket], expected.word == word, expected.origin == origin else {
                // The public display destination is never an input route, even for foreign traffic.
                audit.increment("owned_foreign_display_receipts_ignored"); continue
            }
            guard receipts.count < Self.receiptLimit else { faultLocked(.receiptOverflow); return }
            displayAwaiting.removeFirst(); receipts.append(ticket)
        }
    }

    func send(_ message: HardwareDisplayMessage, expectedOrigin: HardwareEndpointOrigin) throws {
        try validateOwnedEndpoints()
        let word = try message.word(configuration: configuration)
        lock.lock()
        guard connected, failure == nil, expectedOrigin == origin else { lock.unlock(); throw ControlContractError("invalid_transition") }
        guard displayTickets.count < Self.receiptLimit else { faultLocked(.receiptOverflow); lock.unlock(); throw OwnedRehearsalFailure.receiptOverflow }
        let ticket: UInt64
        do { ticket = try nextTicketLocked() }
        catch { faultLocked(.transport); lock.unlock(); throw error }
        let captured = origin, dst = destination
        displayTickets[ticket] = .init(ticket: ticket, word: word, origin: captured); displayAwaiting.append(ticket)
        lock.unlock()
        do { try system.display(message, configuration: configuration, output: output, destination: dst) }
        catch { lock.lock(); faultLocked(.transport); lock.unlock(); throw error }
        audit.emitOwned("owned_virtual_send_accepted", origin: captured, word: word, ticket: ticket)
        lock.lock(); displayTickets[ticket]?.accepted = true
        let stillCurrent = failure == nil && connected && origin == captured
        lock.unlock()
        guard stillCurrent else { throw OwnedRehearsalFailure.staleGeneration }
    }

    private func drainReceipts() {
        lock.lock()
        let result = receipts.compactMap { displayTickets.removeValue(forKey: $0) }
        receipts.removeAll(keepingCapacity: true)
        lock.unlock()
        for receipt in result {
            audit.emitOwned("owned_virtual_display_receipt", origin: receipt.origin, word: receipt.word, ticket: receipt.ticket, accepted: receipt.accepted)
        }
    }

    func drain() throws -> [HardwareMIDIEvent] {
        lock.lock(); let currentFailure = failure; lock.unlock()
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
        displayTickets.removeAll(); displayAwaiting.removeAll(); receipts.removeAll()
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
        if cleanupStarted {
            if cleanupUncertain {
                throw OwnedRehearsalFailure.cleanup
            }
            return
        }
        cleanupStarted = true
        var failed = cleanupUncertain
        do { try closeEndpoints() } catch { failed = true }
        for port in [input, output] where port != 0 {
            do { try system.disposePort(port) } catch { failed = true }
        }
        input = 0; output = 0
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
