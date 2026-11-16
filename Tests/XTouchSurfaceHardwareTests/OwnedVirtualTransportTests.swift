import Foundation
import SurfaceControlContracts
import Testing
import XTouchCompactCore
@testable import XTouchSurfaceHardware

private final class StepFeed {
    var batches: [[OwnedRehearsalStep]] = []
    func next() -> [OwnedRehearsalStep] {
        batches.isEmpty ? [] : batches.removeFirst()
    }
}

private final class OwnedSystemFake: OwnedVirtualMIDISystem {
    var nextRef: UInt32 = 10
    var identities: [UInt32: Int32] = [:]
    var endpoints: Set<UInt32> = []
    var ports: Set<UInt32> = []
    var removed: (@Sendable (UInt32) -> Void)?
    var receiver: (@Sendable (Result<[UInt32], OwnedRehearsalFailure>, UInt64) -> Void)?
    var destinations: [UInt32: @Sendable (Result<[UInt32], OwnedRehearsalFailure>) -> Void] = [:]
    var generation: UInt64 = 0
    var connectedSource: UInt32 = 0
    var holdInputs = false
    var holdDisplays = false
    var published: [(UInt32, UInt32, UInt64)] = []
    var sent: [(UInt32, UInt32)] = []
    var disposed: [UInt32] = []
    var disposedPorts: [UInt32] = []
    var failDispose = false
    var sendHook: (() -> Void)?
    private func ref() -> UInt32 {
        nextRef += 1; return nextRef
    }

    func client(removed: @escaping @Sendable (UInt32) -> Void) throws -> UInt32 {
        self.removed = removed; return ref()
    }

    func source(client _: UInt32) throws -> UInt32 {
        let r = ref(); endpoints.insert(r); identities[r] = Int32(r); return r
    }

    func destination(client _: UInt32, receive: @escaping @Sendable (Result<[UInt32], OwnedRehearsalFailure>) -> Void) throws -> UInt32 {
        let r = ref(); endpoints.insert(r); identities[r] = Int32(r); destinations[r] = receive; return r
    }

    func input(client _: UInt32, receive: @escaping @Sendable (Result<[UInt32], OwnedRehearsalFailure>, UInt64) -> Void) throws -> UInt32 {
        receiver = receive; let r = ref(); ports.insert(r); return r
    }

    func output(client _: UInt32) throws -> UInt32 {
        let r = ref(); ports.insert(r); return r
    }

    func identity(_ endpoint: UInt32) throws -> Int32 {
        guard let id = identities[endpoint], endpoints.contains(endpoint) else { throw OwnedRehearsalFailure.endpointOwnership }; return id
    }

    func connect(input: UInt32, source: UInt32, generation: UInt64) throws {
        guard ports.contains(input), endpoints.contains(source) else { throw OwnedRehearsalFailure.endpointOwnership }
        connectedSource = source; self.generation = generation
    }

    func disconnect(input: UInt32, source: UInt32) throws {
        guard ports.contains(input), endpoints.contains(source) else { throw OwnedRehearsalFailure.cleanup }
        connectedSource = 0
    }

    func publish(source: UInt32, word: UInt32) throws {
        guard source == connectedSource, endpoints.contains(source) else { throw OwnedRehearsalFailure.endpointOwnership }
        published.append((source, word, generation))
        if !holdInputs {
            receiver?(.success([word]), generation)
        }
    }

    func display(_ message: HardwareDisplayMessage, configuration: CompactHardwareConfiguration, output: UInt32, destination: UInt32) throws {
        guard ports.contains(output), endpoints.contains(destination) else { throw OwnedRehearsalFailure.endpointOwnership }
        let word = try message.word(configuration: configuration)
        sent.append((destination, word))
        if !holdDisplays {
            destinations[destination]?(.success([word]))
        }
        sendHook?()
    }

    func disposeEndpoint(_ endpoint: UInt32) throws {
        disposed.append(endpoint)
        guard !failDispose, endpoints.remove(endpoint) != nil else { throw OwnedRehearsalFailure.cleanup }
        identities.removeValue(forKey: endpoint); destinations.removeValue(forKey: endpoint)
    }

    func disposePort(_ port: UInt32) throws {
        disposedPorts.append(port)
        guard !failDispose, ports.remove(port) != nil else { throw OwnedRehearsalFailure.cleanup }
    }
}

private func fixture() throws -> (OwnedVirtualHardwareMIDI, OwnedSystemFake, StepFeed, DeviceAccessAudit) {
    let system = OwnedSystemFake(), feed = StepFeed(), audit = DeviceAccessAudit(access: .enabled)
    let configuration = try CompactHardwareConfiguration(receiveChannel: 1, lightProtocol: .observed114)
    let transport = try OwnedVirtualHardwareMIDI(system: system, configuration: configuration, audit: audit, steps: { feed.next() })
    return (transport, system, feed, audit)
}

private func leases(_ events: [HardwareMIDIEvent]) -> [OwnedInputLease] {
    events.compactMap {
        if case let .ownedInput(value) = $0 {
            value
        } else {
            nil
        }
    }
}

@Test func ownedStartupAndReconnectionNeverSendOrReplayAndUseOnlyOwnedReferences() throws {
    let (transport, system, feed, _) = try fixture()
    let first = transport.currentOrigin
    #expect(first.inputID != nil && first.outputID != nil && first.transportOrigin == "localVirtual")
    #expect(system.sent.isEmpty && system.published.isEmpty)
    _ = try transport.drain()
    transport.startPeer()
    feed.batches = [[.disconnect], [.reconnect]]
    _ = try transport.drain(); _ = try transport.drain()
    let fresh = transport.currentOrigin
    #expect(fresh != first && fresh.connectionGeneration > first.connectionGeneration)
    #expect(system.sent.isEmpty && system.published.isEmpty)
    #expect(system.disposed.count == 2 && system.disposed.allSatisfy { $0 >= 10 })
    #expect(system.ports.count == 2)
}

@Test func ownedInputLeaseRemainsChargedUntilFinalCanonicalCommitAndCannotCommitTwice() throws {
    let (transport, system, feed, audit) = try fixture()
    transport.startPeer()
    let origin = transport.currentOrigin
    feed.batches = [[.input(.controlChange(channel: 0, number: 37, value: 47), generation: origin.connectionGeneration)]]
    let lease = try #require(leases(transport.drain()).first)
    #expect(system.published.count == 1 && transport.outstandingInputCount == 1)
    #expect(lease.origin == origin && lease.receivedAt != nil)
    var committed = 0
    try transport.commit(lease, accepted: true) { committed += 1 }
    #expect(committed == 1 && transport.outstandingInputCount == 0)
    #expect(throws: OwnedRehearsalFailure.self) { try transport.commit(lease, accepted: true) { committed += 1 } }
    #expect(committed == 1 && audit.snapshot["owned_input_owner_accepted"] == 1)
    #expect(system.sent.isEmpty)
}

@Test func ownedPublicationBacklogIsBoundedBeforeTheCoreMIDIHop() throws {
    let (transport, system, feed, _) = try fixture()
    system.holdInputs = true; transport.startPeer()
    let generation = transport.currentOrigin.connectionGeneration
    for _ in 0 ..< OwnedVirtualHardwareMIDI.inputLimit / OwnedRehearsalSteps.commandLimit {
        feed.batches = [Array(repeating: .input(.controlChange(channel: 0, number: 37, value: 1), generation: generation), count: OwnedRehearsalSteps.commandLimit)]
        _ = try transport.drain()
    }
    #expect(transport.outstandingInputCount == OwnedVirtualHardwareMIDI.inputLimit)
    #expect(system.published.count == OwnedVirtualHardwareMIDI.inputLimit)
    feed.batches = [[.input(.controlChange(channel: 0, number: 37, value: 2), generation: generation)]]
    #expect(throws: OwnedRehearsalFailure.self) { try transport.drain() }
    #expect(system.published.count == OwnedVirtualHardwareMIDI.inputLimit)
    #expect(transport.outstandingInputCount == OwnedVirtualHardwareMIDI.inputLimit)
    try transport.cleanup()
    #expect(transport.outstandingInputCount == 0)
}

@Test func ownedHandoffDoesNotReleaseCapacityAndFaultedTicketsCannotRenewPermission() throws {
    let (transport, system, feed, _) = try fixture()
    transport.startPeer()
    let generation = transport.currentOrigin.connectionGeneration
    var first: OwnedInputLease?
    for _ in 0 ..< OwnedVirtualHardwareMIDI.inputLimit / OwnedRehearsalSteps.commandLimit {
        feed.batches = [Array(repeating: .input(.controlChange(channel: 0, number: 37, value: 1), generation: generation), count: OwnedRehearsalSteps.commandLimit)]
        let batch = try leases(transport.drain()); first = first ?? batch.first
    }
    #expect(transport.outstandingInputCount == OwnedVirtualHardwareMIDI.inputLimit)
    feed.batches = [[.input(.controlChange(channel: 0, number: 37, value: 2), generation: generation)]]
    #expect(throws: OwnedRehearsalFailure.self) { try transport.drain() }
    let lease = try #require(first)
    var called = false
    #expect(throws: OwnedRehearsalFailure.self) { try transport.commit(lease, accepted: true) { called = true } }
    transport.reject(lease)
    #expect(!called && system.published.count == OwnedVirtualHardwareMIDI.inputLimit)
    #expect(throws: OwnedRehearsalFailure.self) { try transport.drain() }
}

@Test func ownedRemovalDuringPendingInputOrLastSendCannotCommitAnOldCandidate() throws {
    let (transport, system, feed, _) = try fixture()
    transport.startPeer()
    let origin = transport.currentOrigin
    feed.batches = [[.input(.controlChange(channel: 0, number: 37, value: 47), generation: origin.connectionGeneration)]]
    let lease = try #require(leases(transport.drain()).first)
    system.removed?(system.connectedSource)
    var committed = false
    #expect(throws: OwnedRehearsalFailure.self) { try transport.commit(lease, accepted: true) { committed = true } }
    transport.reject(lease)
    #expect(!committed)
    let (other, wire, _, _) = try fixture()
    let captured = other.currentOrigin
    wire.sendHook = { wire.removed?(wire.connectedSource) }
    #expect(throws: OwnedRehearsalFailure.self) { try other.send(.ringDisplay(encoder: 1, value: 5), expectedOrigin: captured) }
    #expect(!wire.sent.isEmpty && wire.sent.count == 1)
    #expect(throws: OwnedRehearsalFailure.self) { try other.commitFeedback(expectedOrigin: captured) { committed = true } }
    #expect(!committed)
}

@Test func ownedDisplayReceiptsNeverCreateInputAndCannotConsumeInputBudget() throws {
    let (transport, system, feed, _) = try fixture()
    transport.startPeer()
    let origin = transport.currentOrigin
    for _ in 0 ..< 50 {
        try transport.send(.ringDisplay(encoder: 1, value: 5), expectedOrigin: origin)
    }
    #expect(transport.outstandingInputCount == 0)
    for callback in system.destinations.values {
        callback(.success([0x20B0_0164]))
    }
    #expect(try leases(transport.drain()).isEmpty && system.published.isEmpty)
    feed.batches = [[.input(.controlChange(channel: 0, number: 37, value: 47), generation: origin.connectionGeneration)]]
    let input = try #require(leases(transport.drain()).first)
    #expect(transport.outstandingInputCount == 1)
    try transport.commit(input, accepted: true) {}
    #expect(system.sent.count == 50 && transport.outstandingInputCount == 0)
    #expect(system.sent.allSatisfy { (($0.1 >> 16) & 0xF0) == 0xB0 && (($0.1 >> 8) & 127) >= 10 })
}

@Test func ownedDisplayReservationIsBoundedBeforeSendAndOldPinsFailClosed() throws {
    let (transport, system, _, _) = try fixture()
    system.holdDisplays = true
    let origin = transport.currentOrigin
    var stale = origin; stale.connectionGeneration += 1
    #expect(throws: ControlContractError("invalid_transition")) { try transport.send(.ringDisplay(encoder: 1, value: 3), expectedOrigin: stale) }
    #expect(system.sent.isEmpty)
    for _ in 0 ..< OwnedVirtualHardwareMIDI.receiptLimit {
        try transport.send(.ringDisplay(encoder: 1, value: 3), expectedOrigin: origin)
    }
    #expect(throws: OwnedRehearsalFailure.self) { try transport.send(.ringDisplay(encoder: 1, value: 4), expectedOrigin: origin) }
    #expect(system.sent.count == OwnedVirtualHardwareMIDI.receiptLimit)
}

@Test func ownedCleanupFailureIsVisibleAndNeverRetriesNativeDisposal() throws {
    let (transport, system, _, _) = try fixture()
    system.failDispose = true
    #expect(throws: OwnedRehearsalFailure.cleanup) { try transport.cleanup() }
    let attempted = system.disposed.count + system.disposedPorts.count
    #expect(attempted == 4)
    #expect(throws: OwnedRehearsalFailure.cleanup) { try transport.cleanup() }
    #expect(system.disposed.count + system.disposedPorts.count == attempted)
    #expect(system.sent.isEmpty)
}
