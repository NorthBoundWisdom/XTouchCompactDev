import Foundation
import SurfaceControlContracts
import SurfacePluginContracts
import Testing
@testable import XTouchCompactCore

private func input(_ simulator: CompactSurfaceSimulator, _ id: String = "a.encoder.1", _ value: JSONValue = .number(127), encoding: String = "scalar") -> ControlInput {
    .init(expected: simulator.controls.expected, expectedSequence: simulator.controls.discovery().latest_sequence, controlID: id, encoding: encoding, value: value)
}

private func feedback(_ simulator: CompactSurfaceSimulator, _ id: String, _ value: JSONValue, kind: String = "value") -> ControlFeedback {
    .init(expected: simulator.controls.expected, expectedSequence: simulator.controls.discovery().latest_sequence, controlID: id, kind: kind, value: value)
}

@Test func simulationProfileDeclaresActualLayeredCapabilitiesAndMappings() throws {
    let simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch")
    let discovery = simulator.controls.discovery()
    #expect(discovery.source == .simulation)
    #expect(discovery.profile.controls.count == 178)
    #expect(!discovery.profile.controls.contains { $0.input_kind == .relative })
    #expect(discovery.profile.controls.first { $0.id == "a.encoder.1" }?.mapping?.id == "simulation.arm")
    #expect(discovery.profile.controls.first { $0.id == "a.encoder.5" }?.mapping?.id == "simulation.progress")
    #expect(discovery.profile.controls.first { $0.id == "b.touch.9" }?.feedback_kinds.isEmpty == true)
    #expect(simulator.session.parameters.values.values.allSatisfy { $0 == 0 })
    #expect(simulator.mock.faders.allSatisfy { $0 == 0 })
}

@Test func publicInputTraversesOriginalSessionAndIsExplicitSimulation() throws {
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch")
    let event = try simulator.input(input(simulator), at: 1)
    #expect(event.source == .simulation && event.origin == .remote && event.kind == .input)
    #expect(event.disposition == .accepted && event.mapped_value?.finiteNumber == 127)
    #expect(simulator.session.parameters.values["simulation.arm"] == 127)
    #expect(simulator.mock.encoders[0] == 127)
    #expect(simulator.mock.rings[0] == .position(13))
    let duplicate = try simulator.input(input(simulator), at: 2)
    #expect(duplicate.disposition == .ignored && duplicate.reason == "no_change")
    #expect(try (simulator.controls.snapshot(at: 100)).latest_sequence == "2")
}

@Test func invalidPublicInputCannotPartiallyMoveMockOrEngine() throws {
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch")
    _ = try simulator.input(input(simulator, "a.encoder.1", .number(5)), at: 2)
    let snapshot = try (simulator.controls.snapshot(at: 100))
    let samples: [(ControlInput, Double)] = [
        (input(simulator, "a.encoder.1", .number(4), encoding: "signedDelta"), 3),
        (input(simulator, "a.encoder.1", .double(1.5)), 3),
        (input(simulator, "a.encoder.1", .number(128)), 3),
        (input(simulator, "a.encoder.1", .number(12)), 1),
        (input(simulator, "missing", .number(12)), 3),
    ]
    for (request, time) in samples {
        #expect(throws: ControlContractError.self) { try simulator.input(request, at: time) }
        #expect(try (simulator.controls.snapshot(at: 100)) == snapshot)
        #expect(simulator.session.parameters.values["simulation.arm"] == 5)
        #expect(simulator.mock.encoders[0] == 5)
    }
}

@Test func protectedMappingIsNeverBypassedBySimulationInput() throws {
    for definition in [ParameterDefinition(id: "p", name: "p", agentWritable: false),
                       ParameterDefinition(id: "p", name: "p", externallyProtected: true)]
    {
        let config = SurfaceConfiguration(parameters: [definition], assignments: [.init(control: .encoder(1), layer: .a, action: .parameter("p"))], version: definition.externallyProtected == nil ? 1 : 2)
        var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch", configuration: config)
        #expect(throws: ControlContractError("permission_denied")) { try simulator.input(input(simulator), at: 0) }
        #expect(throws: ControlContractError("permission_denied")) { try simulator.input(input(simulator, "a.encoder.1", .number(0)), at: 0) }
        #expect(simulator.session.parameters.values["p"] == 0)
        #expect(simulator.mock.encoders[0] == 0)
        #expect(try (simulator.controls.snapshot(at: 100)).latest_sequence == "0")
    }
}

@Test func publicFeedbackChangesOnlyDisplayAndNeverParameterOrInput() throws {
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch")
    let before = simulator.session.parameters.values
    let beforeInputs = try simulator.controls.snapshot(at: 0).inputs
    _ = try simulator.feedback(feedback(simulator, "a.encoder.1", .number(127)), at: 0)
    _ = try simulator.feedback(feedback(simulator, "a.button.1", .string("blink"), kind: "indicator"), at: 0)
    _ = try simulator.feedback(feedback(simulator, "a.fader.1", .number(100)), at: 0)
    #expect(simulator.session.parameters.values == before)
    #expect(try (simulator.controls.snapshot(at: 100)).inputs == beforeInputs)
    #expect(simulator.mock.rings[0] == .position(13))
    #expect(simulator.mock.buttons[0] == .blink)
    #expect(simulator.mock.faders[0] == 100)
    #expect(simulator.session.state.observedFader(1) == nil)
    let events = try simulator.controls.events(instanceID: "car.a", epoch: "test-epoch", afterSequence: "0", at: 100)
    #expect(events.events.allSatisfy { $0.kind == .feedback })
    // Original engine updates cannot erase independent authority feedback.
    _ = try simulator.input(input(simulator, "a.button.1", .bool(true), encoding: "boolean"), at: 1)
    #expect(simulator.mock.buttons[0] == .blink)
}

@Test func simulationFeedbackRespectsTouchAndRemainsSeparateFromObservation() throws {
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch")
    _ = try simulator.input(input(simulator, "a.touch.1", .bool(true), encoding: "boolean"), at: 0)
    _ = try simulator.feedback(feedback(simulator, "a.fader.1", .number(100)), at: 0)
    #expect(simulator.mock.faders[0] == 0)
    #expect(simulator.session.state.isMotorPending(1))
    _ = try simulator.input(input(simulator, "a.touch.1", .bool(false), encoding: "boolean"), at: 1)
    #expect(simulator.mock.faders[0] == 100)
    #expect(simulator.session.state.observedFader(1) == nil)
}

@Test func inactiveLayerAndEpochChangesCannotReplayInputsOrFeedback() throws {
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch")
    let old = input(simulator)
    let ignored = try simulator.input(input(simulator, "b.encoder.1"), at: 0)
    #expect(ignored.disposition == .ignored && ignored.reason == "inactive_layer")
    let ignoredFeedback = try simulator.feedback(feedback(simulator, "b.fader.1", .number(127)), at: 0)
    #expect(ignoredFeedback.disposition == .ignored)
    #expect(simulator.mock.faders[0] == 0)
    try simulator.selectLayer(.b, epoch: "layer-epoch", at: 1)
    #expect(throws: ControlContractError("stale_epoch")) { try simulator.input(old, at: 1) }
    #expect(simulator.mock.layer == .b && simulator.session.state.layer == .b)
    #expect(simulator.mock.faders.allSatisfy { $0 == 0 })
    try simulator.reset(epoch: "reset-epoch", at: 1)
    #expect(try (simulator.controls.snapshot(at: 100)).inputs.values.allSatisfy { $0 == .number(0) || $0 == .bool(false) })
    #expect(try (simulator.controls.snapshot(at: 100)).latest_sequence == "0")
    #expect(simulator.session.state.layer == .a && simulator.mock.layer == .a)
}

@Test func simulationInstancesAndBoundedJournalAreIndependent() throws {
    var a = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "epoch-a", eventCapacity: 2)
    let b = try CompactSurfaceSimulator(instanceID: "car.b", epoch: "epoch-b", eventCapacity: 2)
    for index in 0 ... 3 {
        _ = try a.input(input(a, "a.encoder.1", .number(index)), at: Double(index))
    }
    #expect(throws: ControlContractError("event_gap")) { try a.controls.events(instanceID: "car.a", epoch: "epoch-a", afterSequence: "0", at: 100) }
    #expect(try (b.controls.snapshot(at: 100)).latest_sequence == "0")
    #expect(b.session.parameters.values["simulation.arm"] == 0)
    let bSnapshot = try (b.controls.snapshot(at: 100))
    try a.reset(epoch: "epoch-a-new", at: 4)
    #expect(a.controls.eventCapacity == 2)
    #expect(try (b.controls.snapshot(at: 100)) == bSnapshot)
}
