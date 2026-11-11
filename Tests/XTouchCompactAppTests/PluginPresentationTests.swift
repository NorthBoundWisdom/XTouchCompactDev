#if os(macOS)
    import ChassisRemoteBinding
    import Combine
    import SimulationContracts
    import SurfacePluginContracts
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @Test @MainActor func activeSimulationPublishesActualDetailEvenWhenSemanticIsUnchanged() throws {
        let clock = TestClock()
        let model = ConsoleModel(startsMIDI: false, now: { clock.date })
        model.installOptionalPlugins([.chassis])
        var binding = try #require(model.plugins.binding("chassis", as: ChassisRemoteBinding.self))
        try binding.plugin.simulator.initialize([0, 0, 0], generation: binding.plugin.simulator.control.generation)
        let grant = try binding.plugin.simulator.acquire(generation: binding.plugin.simulator.control.generation, owner: "test", ttl: 1, controlToken: "opaque-test-grant")
        try binding.plugin.simulator.enable(.init(generation: grant.generation, token: grant.control_token, sequence: 1))
        try binding.plugin.simulator.drive(.init(generation: grant.generation, token: grant.control_token, sequence: 2), speed: 0.3, steering: 0, validFor: 0.4)
        var next = model.plugins
        try next.replaceBinding(binding, at: model.runtimeTime, event: .init(code: "test.drive"))
        try model.commitPlugins(next)
        clock.time += 0.1
        model.advanceAgents()
        let first = model.panelSnapshot.businessPlugins
        let snapshot = model.plugins.snapshots["chassis"]
        var publications = 0
        let subscription = model.objectWillChange.sink { publications += 1 }
        clock.time += 0.1
        model.advanceAgents()
        #expect(model.plugins.snapshots["chassis"] == snapshot)
        #expect(model.panelSnapshot.businessPlugins != first)
        #expect(publications > 0)
        withExtendedLifetime(subscription) {}
    }

    @Test @MainActor func explicitOptionalCompositionAndProtectedExampleNeverRecallMotors() {
        let model = ConsoleModel(startsMIDI: false)
        #expect(model.plugins.instanceIDs == ["agent"])
        model.installOptionalPlugins(Set(OptionalBusinessPlugin.allCases))
        #expect(model.panelSnapshot.businessPlugins.count == 3)
        #expect(model.plugins.instanceIDs.count == 4)
        model.loadReferenceArmExample()
        #expect(model.session.parameters.configuration.version == 2)
        #expect(model.session.parameters.definition("arm.enabled")?.externallyProtected == true)
        #expect(model.session.parameters.configuration.assignments.isEmpty)
        #expect(!model.events.contains { event in
            if event.direction == .output, case .fader = event.control {
                return true
            }; return false
        })
        #expect(model.mock.faders.allSatisfy { $0 == 0 })
    }
#endif
