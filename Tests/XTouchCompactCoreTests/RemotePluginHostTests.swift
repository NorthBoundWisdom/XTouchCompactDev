import AgentPlugin
import AgentRemoteBinding
import RemoteToolContracts
import SurfacePluginContracts
import Testing
@testable import XTouchCompactCore

@Test func hostAndSharedRegistryExposeIdenticalSchemasAndAgentResults() throws {
    var host = try CompactPluginHost.agent()
    var reference = try RemoteRegistry(epoch: "reference")
    try reference.install(AgentRemoteBinding(instanceID: "agent", plugin: AgentPlugin(approvalPolicy: .localOrigins)))
    _ = try reference.handle(instanceID: "agent", input: .start, at: 0)
    #expect(host.remoteTools == reference.tools)
    let arguments: JSONValue = .object(["instance_id": .string("agent"), "slot": .number(1)])
    let context = RemoteCallContext(time: 1)
    #expect(try host.callRemote("surface_agent_primary", arguments: arguments, context: context) == reference.call("surface_agent_primary", arguments: arguments, context: context))
    for time in [1.45, 2.0, 3.7] {
        try host.advance(to: time)
        _ = try reference.handle(instanceID: "agent", input: .advance, at: time)
        #expect(host.snapshots["agent"] == reference.snapshot(instanceID: "agent"))
        let read: JSONValue = .object(["instance_id": .string("agent")])
        #expect(try host.callRemote("surface_agent_snapshot", arguments: read, context: .init(time: time)) == reference.call("surface_agent_snapshot", arguments: read, context: .init(time: time)))
    }
    #expect(throws: RemoteFailure.self) { try host.callRemote("surface_agent_primary", arguments: arguments, context: .init(time: 4)) }
    #expect(AgentPresentation(host).slots[0].phase == .waitingApproval)
}

@Test func remoteEventsKeepEpochGapAndFailedCallsAtomicAndReadsPure() throws {
    var host = try CompactPluginHost.agent()
    func events(_ epoch: String, _ cursor: String) -> JSONValue {
        .object(["epoch": .string(epoch), "after": .string(cursor), "limit": .number(256)])
    }
    let first = try host.callRemote("surface_events", arguments: events("old-session", "0"), context: .init(time: 0))
    #expect(first.value(for: "gap") == .bool(true))
    let epoch = try #require(first.value(for: "epoch")?.stringValue)
    let firstSequence = try #require(first.value(for: "latestSequence")?.intValue)
    let cursor = String(firstSequence)
    _ = try host.callRemote("surface_agent_snapshot", arguments: .object(["instance_id": .string("agent")]), context: .init(time: 0))
    let before = host.snapshots
    for slot in [JSONValue.double(1.5), .bool(true), .number(0)] {
        #expect(throws: RemoteFailure.self) {
            try host.callRemote("surface_agent_primary", arguments: .object(["instance_id": .string("agent"), "slot": slot]), context: .init(time: 1))
        }
    }
    #expect(host.snapshots == before)
    let unchanged = try host.callRemote("surface_events", arguments: events(epoch, cursor), context: .init(time: 1))
    #expect(unchanged.value(for: "events") == .array([]))
    #expect(unchanged.value(for: "latestSequence")?.intValue == firstSequence)
    for index in 1 ... 260 {
        _ = try host.callRemote("surface_agent_primary", arguments: .object(["instance_id": .string("agent"), "slot": .number(1)]), context: .init(time: Double(index)))
    }
    let slow = try host.callRemote("surface_events", arguments: events(epoch, "0"), context: .init(time: 260))
    #expect(slow.value(for: "gap") == .bool(true))
    #expect(slow.value(for: "events")?.arrayValue?.count == 256)
    let future = try host.callRemote("surface_events", arguments: events(epoch, "9999"), context: .init(time: 260))
    #expect(future.value(for: "gap") == .bool(true))
    let fresh = try CompactPluginHost.agent()
    #expect(fresh.remoteTools == host.remoteTools)
}
