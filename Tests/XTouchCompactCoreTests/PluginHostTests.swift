import AgentPlugin
import AgentRemoteBinding
import SurfacePluginContracts
import Testing
@testable import XTouchCompactCore

@Test func pluginRegistrationIsAtomicAcrossDuplicateMalformedAndFailedStarts() throws {
    var host = CompactPluginHost()
    let valid = FixturePlugin(id: "first")
    #expect(throws: PluginHostError.self) { try host.register([valid, valid], at: 0) }
    #expect(host.manifests.isEmpty && host.parameterValues.isEmpty)
    #expect(throws: PluginHostError.self) { try host.register([valid, FixturePlugin(id: "bad", version: "2")], at: 0) }
    #expect(host.manifests.isEmpty)
    #expect(throws: PluginHostError.self) { try host.register([valid, FixturePlugin(id: "bad", invalidWrite: true)], at: 0) }
    #expect(host.manifests.isEmpty && host.parameterValues.isEmpty)
    try host.register([valid, FixturePlugin(id: "second")], at: 0)
    #expect(host.manifests.count == 2)
    #expect(host.parameterValues.count == 2)
    let before = host.snapshots
    #expect(throws: PluginHostError.self) {
        try host.handle(.invoke(.init(pluginID: "first", actionID: "first.run", index: 3), origin: .interface), pluginID: "first", at: 1)
    }
    #expect(host.snapshots == before)
    try host.handle(.stop, pluginID: "first", at: 1)
    #expect(host.snapshots["first"]?.isStarted == false)
    #expect(host.snapshots["second"]?.isStarted == true)
}

@Test func sharedAgentSequenceMatchesTypedPluginAndRejectsUntrustedApprovalAtomically() throws {
    var host = try CompactPluginHost.agent()
    var reference = try AgentPlugin(approvalPolicy: .localOrigins)
    _ = try reference.handle(.start, at: 0)
    let action = PluginConfigurationAdapter.agentAction(2)
    for (time, input) in [(1.0, PluginInput.invoke(action, origin: .interface)), (1.45, .advance), (3.65, .advance)] {
        _ = try reference.handle(input, at: time)
        _ = try host.handle(input, pluginID: AgentPlugin.pluginID, at: time)
        #expect(host.snapshots["agent"] == reference.snapshot())
        #expect(host.binding("agent", as: AgentRemoteBinding.self)?.plugin.slots == reference.slots)
    }
    for origin in [InputOrigin.remote] {
        #expect(throws: PluginError(code: .permissionDenied, fields: ["requiredOrigin": .string("interface")])) {
            try host.handle(.invoke(action, origin: origin), pluginID: AgentPlugin.pluginID, at: 4)
        }
        #expect(host.snapshots["agent"] == reference.snapshot())
    }
    try host.handle(.invoke(action, origin: .hardware), pluginID: AgentPlugin.pluginID, at: 4)
    #expect(AgentPresentation(host).slots[1].phase == .running)
    for semantic in IndicatorSemantic.allCases {
        let expected: ButtonLight = semantic == .active ? .on : semantic == .attention ? .blink : .off
        #expect(IndicatorPresentation.light(.init(semantic: semantic)) == expected)
    }
}

@Test func registrationRejectsNestedNamespaceCollisionsAndBadNamesBeforeStarting() throws {
    var host = try CompactPluginHost.agent()
    let original = host.snapshots
    let originalManifests = host.manifests
    let collisions: [[FixturePlugin]] = [
        [.init(id: "a", actionID: "a.b.go"), .init(id: "a.b", actionID: "a.b.go")],
        [.init(id: "a", indicatorID: "a.b.light"), .init(id: "a.b", indicatorID: "a.b.light")],
        [.init(id: "a", actionID: "a.")],
        [.init(id: " bad")], [.init(id: "bad..name")], [.init(id: "a", actionID: "a.bad name")],
    ]
    for batch in collisions {
        #expect(throws: PluginHostError.invalidDescriptor) { try host.register(batch, at: 0) }
        #expect(host.snapshots == original && host.manifests == originalManifests)
    }
    #expect(throws: PluginHostError.invalidDescriptor) {
        try host.register([FixturePlugin(id: "first", failsStart: true), FixturePlugin(id: "bad", actionID: "bad.")], at: 0)
    }
    #expect(host.snapshots == original)
}

@Test func multipleInstancesOfOnePluginStayIsolatedAndDoNotOverrideHardwareBindings() throws {
    var host = try CompactPluginHost.agent()
    try host.registerBindings([AgentRemoteBinding(instanceID: "other-agent", plugin: AgentPlugin(approvalPolicy: .localOrigins))], at: 0)
    try host.handle(.invoke(PluginConfigurationAdapter.agentAction(1), origin: .interface), instanceID: "other-agent", at: 1)
    #expect(host.binding("other-agent", as: AgentRemoteBinding.self)?.plugin.slots[0].state == .queued)
    #expect(AgentPresentation(host).slots[0].phase == .idle)
    #expect(host.feedbackIndicators[AgentPlugin.indicatorID(for: 1)]?.semantic == .idle)
    #expect(throws: PluginHostError.unknownPlugin) {
        try host.handle(.invoke(PluginConfigurationAdapter.agentAction(1), origin: .interface), pluginID: AgentPlugin.pluginID, at: 1)
    }
}

private struct FixturePlugin: ControlPlugin {
    let id: String
    var version = "1.0"
    var invalidWrite = false
    var actionID: String?
    var indicatorID: String?
    var failsStart = false
    var started = false
    var manifest: PluginManifest {
        .init(id: .init(rawValue: id), version: "1", contractVersion: version, source: .mock)
    }

    var surface: SurfaceDescriptor {
        .init(parameters: [try! .init(id: .init(rawValue: "\(id).value"), nameKey: "value", minimum: 0, maximum: 1, defaultValue: 0)],
              actions: [.init(id: .init(rawValue: actionID ?? "\(id).run"), nameKey: "run", indexCount: 2)],
              indicators: indicatorID.map { [.init(id: .init(rawValue: $0), nameKey: "light")] } ?? [])
    }

    func snapshot() -> PluginSnapshot {
        .init(isStarted: started)
    }

    mutating func handle(_ input: PluginInput, at _: PluginTime) throws -> PluginUpdate {
        if input == .start {
            started = true
        }
        if input == .stop {
            started = false
        }
        return invalidWrite ? .init(parameterWrites: [.init(id: "unknown", value: 1, origin: .interface)]) : .init()
    }
}
