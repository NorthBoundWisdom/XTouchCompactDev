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
    // 2 layers x (89 controls + expression + footswitch) + the two physical layer keys.
    #expect(discovery.profile.controls.count == 184)
    #expect(discovery.profile.version == "1.1" && discovery.expected.profile_version == "1.1")
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

@Test func physicalLayerKeysSwitchMockAndSessionWithoutChangingIdentity() throws {
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch")
    let profile = simulator.controls.profile
    for id in ["global.layer.a", "global.layer.b"] {
        let key = try #require(profile.controls.first { $0.id == id })
        #expect(key.input_kind == .button && key.encoding == .boolean && key.feedback_kinds.isEmpty && key.mapping == nil)
    }
    let identity = simulator.controls.expected
    #expect(try simulator.input(input(simulator, "b.encoder.1"), at: 0).reason == "inactive_layer")
    let press = try simulator.input(input(simulator, "global.layer.b", .bool(true), encoding: "boolean"), at: 1)
    #expect(press.kind == .input && press.disposition == .accepted && press.mapped_value == .string("b"))
    #expect(simulator.session.state.layer == .b && simulator.mock.layer == .b)
    // Layer selection is ordinary input: identity and epoch are kept, the sequence advances.
    #expect(simulator.controls.expected == identity)
    #expect(try simulator.input(input(simulator, "global.layer.b", .bool(true), encoding: "boolean"), at: 1).reason == "no_change")
    _ = try simulator.input(input(simulator, "global.layer.b", .bool(false), encoding: "boolean"), at: 1)
    #expect(simulator.session.state.layer == .b)
    // The previously inactive layer is now reachable, and the former active layer is ignored.
    let accepted = try simulator.input(input(simulator, "b.encoder.1", .number(127)), at: 2)
    #expect(accepted.disposition == .accepted)
    #expect(simulator.mock.encoders[0] == 127)
    #expect(simulator.session.bank(.b).encoders[0] == 127)
    #expect(simulator.session.parameters.values["simulation.arm"] == 0)
    #expect(try simulator.input(input(simulator, "a.encoder.1", .number(127)), at: 2).reason == "inactive_layer")
    #expect(try simulator.input(input(simulator, "b.fader.1", .number(55)), at: 2).disposition == .accepted)
    #expect(simulator.mock.faders[0] == 55)
    _ = try simulator.input(input(simulator, "global.layer.a", .bool(true), encoding: "boolean"), at: 3)
    #expect(simulator.session.state.layer == .a && simulator.mock.layer == .a)
    #expect(simulator.controls.expected == identity)
    #expect(try (simulator.controls.snapshot(at: 3)).latest_sequence == "8")
    // No motor recall on layer switch: the B position stays on the motor fader.
    #expect(simulator.mock.faders[0] == 55)
    let events = try simulator.controls.events(instanceID: "car.a", epoch: "test-epoch", afterSequence: "0", at: 3)
    #expect(events.events.allSatisfy { $0.kind == .input && $0.origin == .remote && $0.source == .simulation })
}

@Test func layerKeyNeverReassertsFaderOverlayOrRecallsMotors() throws {
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch")
    _ = try simulator.feedback(feedback(simulator, "a.fader.1", .number(100)), at: 0)
    _ = try simulator.feedback(feedback(simulator, "a.encoder.2", .number(127)), at: 0)
    _ = try simulator.feedback(feedback(simulator, "a.button.3", .string("blink"), kind: "indicator"), at: 0)
    #expect(simulator.mock.faders[0] == 100)
    _ = try simulator.input(input(simulator, "global.layer.b", .bool(true), encoding: "boolean"), at: 1)
    _ = try simulator.input(input(simulator, "b.fader.1", .number(10)), at: 1)
    _ = try simulator.input(input(simulator, "global.layer.a", .bool(true), encoding: "boolean"), at: 2)
    // Ring and indicator display intent of the active layer is redrawn; the fader is not driven.
    #expect(simulator.mock.faders[0] == 10)
    #expect(simulator.mock.rings[1] == .position(13))
    #expect(simulator.mock.buttons[2] == .blink)
    #expect(simulator.mock.ignoredMotorCommands == 0)
}

@Test func acceptedFaderInputIsNotPulledBackByItsOwnOverlay() throws {
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch")
    _ = try simulator.feedback(feedback(simulator, "a.fader.1", .number(80)), at: 0)
    _ = try simulator.feedback(feedback(simulator, "a.fader.2", .number(90)), at: 0)
    #expect(simulator.mock.faders[0] == 80 && simulator.mock.faders[1] == 90)
    let event = try simulator.input(input(simulator, "a.fader.1", .number(30)), at: 1)
    #expect(event.disposition == .accepted)
    #expect(simulator.mock.faders[0] == 30)
    #expect(try (simulator.controls.snapshot(at: 1)).inputs["a.fader.1"] == .number(30))
    // Later inputs elsewhere still do not resurrect the superseded fader overlay.
    _ = try simulator.input(input(simulator, "a.encoder.3", .number(50)), at: 2)
    #expect(simulator.mock.faders[0] == 30)
    #expect(simulator.mock.faders[1] == 90)
    // A new display request re-arms the overlay explicitly.
    _ = try simulator.feedback(feedback(simulator, "a.fader.1", .number(70)), at: 3)
    #expect(simulator.mock.faders[0] == 70)
    // Ring and indicator overlays on the input control itself remain display intent.
    _ = try simulator.feedback(feedback(simulator, "a.encoder.4", .number(0)), at: 4)
    _ = try simulator.input(input(simulator, "a.encoder.4", .number(127)), at: 4)
    #expect(simulator.mock.encoders[3] == 127 && simulator.mock.rings[3] == .position(1))
}

@Test func pedalsAreLayeredInputOnlyControlsUsingTheMockGestures() throws {
    var configuration = CompactSurfaceSimulator.demonstrationConfiguration
    configuration.parameters.append(ParameterDefinition(id: "pedal.level", name: "Level"))
    configuration.parameters.append(ParameterDefinition(id: "pedal.hold", name: "Hold", isSwitch: true))
    configuration.assignments.append(.init(control: .expression, layer: .a, action: .parameter("pedal.level")))
    configuration.assignments.append(.init(control: .footswitch, layer: .a, action: .parameter("pedal.hold")))
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch", configuration: configuration)
    let controls = simulator.controls.profile.controls
    for layer in ["a", "b"] {
        let expression = try #require(controls.first { $0.id == "\(layer).expression.1" })
        #expect(expression.input_kind == .absolute && expression.encoding == .scalar && expression.range == .init(minimum: 0, maximum: 127, step: 1))
        let footswitch = try #require(controls.first { $0.id == "\(layer).footswitch.1" })
        #expect(footswitch.input_kind == .button && footswitch.encoding == .boolean)
        #expect(expression.feedback_kinds.isEmpty && footswitch.feedback_kinds.isEmpty)
    }
    #expect(controls.first { $0.id == "a.expression.1" }?.mapping?.id == "pedal.level")
    let seeded = try simulator.controls.snapshot(at: 0).inputs
    #expect(seeded["a.expression.1"] == nil && seeded["a.footswitch.1"] == .bool(false))
    let moved = try simulator.input(input(simulator, "a.expression.1", .number(127)), at: 1)
    #expect(moved.disposition == .accepted && moved.mapped_value?.finiteNumber == 127)
    #expect(simulator.mock.expression == 127 && simulator.session.parameters.values["pedal.level"] == 127)
    _ = try simulator.input(input(simulator, "a.footswitch.1", .bool(true), encoding: "boolean"), at: 2)
    #expect(simulator.mock.footswitchDown && simulator.session.parameters.values["pedal.hold"] == 127)
    #expect(try simulator.input(input(simulator, "b.footswitch.1", .bool(true), encoding: "boolean"), at: 3).reason == "inactive_layer")
    #expect(throws: ControlContractError("unsupported_feedback")) {
        try simulator.feedback(feedback(simulator, "a.expression.1", .number(3)), at: 3)
    }
}

@Test func pedalActionBindingsFollowTheUnsupportedMappingRule() throws {
    var configuration = SurfaceConfiguration.neutral
    configuration.assignments.append(.init(control: .footswitch, layer: .a, action: .set("a.Encoder.4", 100)))
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch", configuration: configuration)
    #expect(simulator.controls.profile.controls.first { $0.id == "a.footswitch.1" }?.mapping == nil)
    #expect(throws: ControlContractError("unsupported_mapping")) {
        try simulator.input(input(simulator, "a.footswitch.1", .bool(true), encoding: "boolean"), at: 0)
    }
    #expect(simulator.session.parameters.values["a.Encoder.4"] == 0)
    #expect(!simulator.mock.footswitchDown)
    #expect(try (simulator.controls.snapshot(at: 0)).latest_sequence == "0")
}

/// R4-27: the Agent motor gate (`setParameter(drivesMotors:)`) is an App policy for Agent
/// writes. Simulated gestures traverse `session.receive` as ordinary input and still drive
/// every other motor bound to the same parameter, exactly as a local hand movement does.
@Test func simulatedInputIsNotSubjectToTheAgentMotorGate() throws {
    let configuration = SurfaceConfiguration(parameters: [ParameterDefinition(id: "p", name: "p")],
                                             assignments: [.init(control: .encoder(1), layer: .a, action: .parameter("p")), .init(control: .fader(2), layer: .a, action: .parameter("p"))])
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch", configuration: configuration)
    #expect(simulator.session.motorFaders(boundTo: "p") == [2])
    _ = try simulator.input(input(simulator, "a.encoder.1", .number(127)), at: 1)
    #expect(simulator.session.parameters.values["p"] == 127)
    #expect(simulator.mock.faders[1] == 127)
    // A touched bound fader is still protected and reconciles only on release.
    _ = try simulator.input(input(simulator, "a.touch.2", .bool(true), encoding: "boolean"), at: 2)
    _ = try simulator.input(input(simulator, "a.encoder.1", .number(0)), at: 3)
    #expect(simulator.mock.faders[1] == 127 && simulator.session.state.isMotorPending(2))
    _ = try simulator.input(input(simulator, "a.touch.2", .bool(false), encoding: "boolean"), at: 4)
    #expect(simulator.mock.faders[1] == 0)
}
