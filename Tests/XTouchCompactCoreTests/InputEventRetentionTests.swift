import SurfaceControlContracts
import SurfacePluginContracts
import Testing
@testable import XTouchCompactCore

private func retainedInput(_ host: CompactSurfaceSimulator, _ id: String, _ value: JSONValue, hold: Double? = nil) -> ControlInput {
    .init(expected: host.controls.expected, expectedSequence: host.controls.discovery().latest_sequence, controlID: id,
          encoding: value.boolValue == nil ? "scalar" : "boolean", value: value, holdSeconds: hold)
}

@Test func explicitInputRetentionKeepsProfileIdentityAndDefaultContractFrozen() throws {
    let legacy = try CompactSurfaceSimulator(instanceID: "test", epoch: "epoch")
    let opted = try CompactSurfaceSimulator(instanceID: "test", epoch: "epoch", inputEventCapacity: 3)
    let old = legacy.controls.discovery(), new = opted.controls.discovery()
    #expect(old.contract_version == "1.3" && old.profile.version == "1.3")
    #expect(new.contract_version == "1.5" && new.profile.version == "1.5")
    #expect(old.profile.id == new.profile.id && old.profile.controls == new.profile.controls)
    #expect(new.profile.capabilities == old.profile.capabilities + ["events.input_retention"])
    #expect(throws: ControlContractError("unsupported_input_retention")) {
        try legacy.controls.inputEvents(expected: old.expected, afterInputSequence: "0", at: 0)
    }
    for invalid in [0, 65537] {
        #expect(throws: ControlContractError("invalid_argument")) {
            try CompactSurfaceSimulator(instanceID: "test", epoch: "epoch", inputEventCapacity: invalid)
        }
    }
}

@Test func retainedInputSurvivesDisplayFloodWhileOriginalGlobalJournalStillGaps() throws {
    var host = try CompactSurfaceSimulator(instanceID: "test", epoch: "epoch", eventCapacity: 2, inputEventCapacity: 2)
    let first = try host.input(retainedInput(host, "a.encoder.1", .number(7)), at: 1)
    for index in 2 ... 6 {
        _ = try host.feedback(.init(expected: host.controls.expected, expectedSequence: host.controls.discovery().latest_sequence,
                                    controlID: "a.encoder.1", kind: "value", value: .number(index)), at: Double(index))
    }
    let page = try host.controls.inputEvents(expected: host.controls.expected, afterInputSequence: "0", at: 7)
    #expect(page.events == [first] && page.input_event_capacity == 2)
    #expect(page.latest_sequence == "6" && page.latest_input_sequence == "1")
    #expect(throws: ControlContractError("event_gap")) {
        try host.controls.events(instanceID: "test", epoch: "epoch", afterSequence: "0", at: 7)
    }
    _ = try host.input(retainedInput(host, "a.encoder.1", .number(7)), at: 8)
    _ = try host.input(retainedInput(host, "a.encoder.1", .number(9)), at: 9)
    #expect(throws: ControlContractError("input_event_gap")) {
        try host.controls.inputEvents(expected: host.controls.expected, afterInputSequence: "0", at: 9)
    }
    let tail = try host.controls.inputEvents(expected: host.controls.expected, afterInputSequence: "1", at: 9)
    #expect(tail.events.map(\.input_sequence) == ["2", "3"])
    #expect(tail.events.first?.disposition == .ignored)
}

@Test func retainedHoldExpiryIsInputWhileRenewIsSilentAndResetPreservesCapacity() throws {
    var host = try CompactSurfaceSimulator(instanceID: "test", epoch: "epoch", inputEventCapacity: 4)
    _ = try host.input(retainedInput(host, "a.touch.1", .bool(true), hold: 1), at: 0)
    _ = try host.renew(.init(expected: host.controls.expected, controlID: "a.touch.1", holdSeconds: 1), at: 0.5)
    #expect(try host.controls.inputEvents(expected: host.controls.expected, afterInputSequence: "0", at: 0.5).events.count == 1)
    _ = try host.processHoldExpiries(at: 1.5)
    let page = try host.controls.inputEvents(expected: host.controls.expected, afterInputSequence: "0", at: 1.5)
    #expect(page.events.map(\.reason) == [nil, "hold_expired"])
    #expect(page.events.map(\.input_sequence) == ["1", "2"] && page.holds == nil)
    let old = host.controls.expected
    try host.reset(epoch: "reset", at: 2)
    #expect(host.controls.inputEventCapacity == 4 && host.controls.discovery().contract_version == "1.5")
    #expect(throws: ControlContractError("stale_epoch")) {
        try host.controls.inputEvents(expected: old, afterInputSequence: "0", at: 2)
    }
    #expect(try host.controls.inputEvents(expected: host.controls.expected, afterInputSequence: "0", at: 2).events.isEmpty)
}

@Test func hardwareRetentionKeepsRealSourceAndReconnectClearsOnlyHistoricalContext() throws {
    var host = try CompactHardwareSurface(instanceID: "test", epoch: "start", configuration: .init(receiveChannel: 1, lightProtocol: .observed114),
                                          hardwareWriterID: "device", remoteWriterID: "remote", inputEventCapacity: 2)
    try host.transition(epoch: "connected", connected: true, at: 0)
    let event = try host.receive(.controlChange(channel: 0, number: 28, value: 47), at: 1)
    let page = try host.controls.inputEvents(expected: host.controls.expected, afterInputSequence: "0", at: 1)
    #expect(try page.events == [#require(event)])
    #expect(page.events.first?.source == .hardware && page.events.first?.origin == .hardware && page.link?.state == .connected)
    let old = host.controls.expected
    try host.transition(epoch: "gone", connected: false, at: 2)
    try host.transition(epoch: "back", connected: true, at: 3)
    #expect(host.controls.inputEventCapacity == 2 && host.observedLayer == nil)
    #expect(throws: ControlContractError("stale_epoch")) {
        try host.controls.inputEvents(expected: old, afterInputSequence: "0", at: 3)
    }
    let empty = try host.controls.inputEvents(expected: host.controls.expected, afterInputSequence: "0", at: 3)
    #expect(empty.events.isEmpty && empty.latest_input_sequence == "0" && empty.link?.state == .connected)
    #expect(try host.controls.snapshot(at: 3).inputs.isEmpty)
}
