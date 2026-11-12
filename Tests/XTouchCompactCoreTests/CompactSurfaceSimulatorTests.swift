import Foundation
import SurfaceControlContracts
import SurfacePluginContracts
import Testing
@testable import XTouchCompactCore

private func input(_ simulator: CompactSurfaceSimulator, _ id: String = "a.encoder.1", _ value: JSONValue = .number(127), encoding: String = "scalar", hold: Double? = nil) -> ControlInput {
    .init(expected: simulator.controls.expected, expectedSequence: simulator.controls.discovery().latest_sequence, controlID: id, encoding: encoding, value: value,
          holdSeconds: hold)
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
    #expect(discovery.profile.version == "1.2" && discovery.expected.profile_version == "1.2")
    #expect(!discovery.profile.controls.contains { $0.input_kind == .relative })
    #expect(discovery.profile.controls.first { $0.id == "a.encoder.1" }?.mapping?.id == "simulation.arm")
    #expect(discovery.profile.controls.first { $0.id == "a.encoder.5" }?.mapping?.id == "simulation.progress")
    #expect(discovery.profile.controls.first { $0.id == "b.touch.9" }?.feedback_kinds.isEmpty == true)
    #expect(simulator.session.parameters.values.values.allSatisfy { $0 == 0 })
    #expect(simulator.mock.faders.allSatisfy { $0 == 0 })
    // Contract 1.2: registered vocabulary plus one XTouch-private rule; mapping revision derived.
    #expect(discovery.profile.capabilities == ["simulation", "controls.stable_ids", "controls.layered", "input.absolute", "input.button",
                                               "input.hold", "feedback.value", "feedback.indicator", "feedback.unsequenced", "controls.input_declared", "x.xtouch.touch_protection"])
    #expect(discovery.contract_version == "1.2")
    #expect(discovery.expected.mapping_revision == discovery.profile.mappingRevision)
    #expect(discovery.expected.mapping_revision.count == 16 && discovery.expected.mapping_revision != "1")
    let held = discovery.profile.controls.filter { $0.hold != nil }.map(\.id)
    #expect(held == (1 ... 9).map { "a.touch.\($0)" } + (1 ... 9).map { "b.touch.\($0)" })
    #expect(discovery.profile.controls.first { $0.id == "a.touch.1" }?.hold == ControlHold(restValue: .bool(false), maxHoldSeconds: 10))
}

@Test func mappingRevisionFollowsMappingContentNotIdentity() throws {
    let first = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "one")
    let second = try CompactSurfaceSimulator(instanceID: "car.b", epoch: "two")
    #expect(first.controls.expected.mapping_revision == second.controls.expected.mapping_revision)
    var remapped = CompactSurfaceSimulator.demonstrationConfiguration
    remapped.assignments.removeAll { $0.control == .encoder(5) }
    let third = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "one", configuration: remapped)
    #expect(third.controls.expected.mapping_revision != first.controls.expected.mapping_revision)
    var reset = first
    try reset.reset(epoch: "reset", at: 1)
    #expect(reset.controls.expected.mapping_revision == first.controls.expected.mapping_revision)
    #expect(reset.controls.expected.epoch == "reset")
}

@Test func normalizedNumericInputIsUnchangedRegardlessOfRepresentation() throws {
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch")
    _ = try simulator.input(input(simulator, "a.encoder.1", .number(80)), at: 1)
    let same = try simulator.input(input(simulator, "a.encoder.1", .double(80)), at: 2)
    #expect(same.disposition == .ignored && same.reason == "no_change")
    #expect(simulator.mock.encoders[0] == 80)
}

@Test func touchLeaseExpiresToReleasedThroughTheRealGestureAndReconcilesTheMotor() throws {
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch")
    #expect(throws: ControlContractError("unsupported_hold")) {
        try simulator.input(input(simulator, "a.button.1", .bool(true), encoding: "boolean", hold: 1), at: 0)
    }
    #expect(throws: ControlContractError("invalid_argument")) {
        try simulator.input(input(simulator, "a.touch.1", .bool(true), encoding: "boolean", hold: 11), at: 0)
    }
    let touched = try simulator.input(input(simulator, "a.touch.1", .bool(true), encoding: "boolean", hold: 1), at: 1)
    #expect(touched.hold_deadline == 2 && simulator.mock.touchedFaders == [1])
    _ = try simulator.feedback(feedback(simulator, "a.fader.1", .number(90)), at: 1.2)
    #expect(simulator.mock.faders[0] == 0 && simulator.session.state.isMotorPending(1))
    let identity = simulator.controls.expected
    let renewed = try simulator.renew(.init(expected: identity, controlID: "a.touch.1", holdSeconds: 1), at: 1.5)
    let afterRenew = try simulator.controls.snapshot(at: 1.5)
    #expect(renewed.hold_deadline == 2.5 && afterRenew.latest_sequence == "2")
    #expect(simulator.nextHoldDeadline == 2.5)
    // Nothing is due yet, so nothing changes.
    #expect(try simulator.processHoldExpiries(at: 2.4).isEmpty)
    #expect(throws: ControlContractError("hold_expiry_pending")) { try simulator.controls.snapshot(at: 2.5) }
    let expired = try simulator.processHoldExpiries(at: 2.5)
    #expect(expired.map(\.control_id) == ["a.touch.1"] && expired.first?.reason == "hold_expired" && expired.first?.origin == .remote)
    // The same release gesture as an input: touch cleared and the withheld display intent reconciled.
    #expect(simulator.mock.touchedFaders.isEmpty && simulator.mock.faders[0] == 90)
    #expect(simulator.session.state.observedFader(1) == nil)
    let afterExpiry = try simulator.controls.snapshot(at: 2.5)
    #expect(afterExpiry.inputs["a.touch.1"] == .bool(false) && afterExpiry.holds == nil)
    #expect(simulator.nextHoldDeadline == nil && simulator.controls.expected == identity)
    #expect(throws: ControlContractError("hold_expired")) {
        try simulator.renew(.init(expected: identity, controlID: "a.touch.1", holdSeconds: 1), at: 2.6)
    }
}

@Test func touchLeaseSurvivesLayerSwitchAndReleasesThePhysicalSensor() throws {
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch")
    _ = try simulator.input(input(simulator, "a.touch.2", .bool(true), encoding: "boolean", hold: 2), at: 0)
    _ = try simulator.input(input(simulator, "global.layer.b", .bool(true), encoding: "boolean"), at: 0.5)
    #expect(simulator.mock.touchedFaders == [2])
    _ = try simulator.processHoldExpiries(at: 2)
    #expect(simulator.mock.touchedFaders.isEmpty && !simulator.session.state.isTouched(2))
    let released = try simulator.controls.snapshot(at: 2)
    #expect(released.inputs["a.touch.2"] == .bool(false))
}

@Test func addingALeaseToTheCurrentTouchDoesNotRepeatTheGesture() throws {
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch")
    _ = try simulator.input(input(simulator, "a.touch.3", .bool(true), encoding: "boolean"), at: 0)
    let messages = simulator.mock.touchedFaders
    let leased = try simulator.input(input(simulator, "a.touch.3", .bool(true), encoding: "boolean", hold: 1), at: 0.5)
    #expect(leased.disposition == .accepted && leased.hold_deadline == 1.5 && simulator.mock.touchedFaders == messages)
    let release = try simulator.input(input(simulator, "a.touch.3", .bool(false), encoding: "boolean"), at: 0.8)
    #expect(release.disposition == .accepted && simulator.nextHoldDeadline == nil && simulator.mock.touchedFaders.isEmpty)
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

@Test func pedalActionBindingsDeclareInputDenied() throws {
    var configuration = SurfaceConfiguration.neutral
    configuration.assignments.append(.init(control: .footswitch, layer: .a, action: .set("a.Encoder.4", 100)))
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch", configuration: configuration)
    #expect(simulator.controls.profile.controls.first { $0.id == "a.footswitch.1" }?.mapping == nil)
    #expect(throws: ControlContractError("permission_denied")) {
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

/// Controls without a mapping are ordinary inputs: accepted, visible in snapshot and journal,
/// applied to the Mock and the layer bank, with no parameter change and no `mapped_value`.
@Test func unmappedControlsAcceptSimulatedInputWithoutParameterEffects() throws {
    var simulator = try CompactSurfaceSimulator(instanceID: "car.a", epoch: "test-epoch")
    let profile = simulator.controls.profile
    for id in ["a.fader.3", "a.encoder.9", "a.button.7", "a.push.2", "a.touch.3"] {
        #expect(profile.controls.first { $0.id == id }?.mapping == nil)
    }
    let parameters = simulator.session.parameters.values
    let fader = try simulator.input(input(simulator, "a.fader.3", .number(64)), at: 1)
    let encoder = try simulator.input(input(simulator, "a.encoder.9", .number(127)), at: 2)
    let button = try simulator.input(input(simulator, "a.button.7", .bool(true), encoding: "boolean"), at: 3)
    let push = try simulator.input(input(simulator, "a.push.2", .bool(true), encoding: "boolean"), at: 4)
    for event in [fader, encoder, button, push] {
        #expect(event.disposition == .accepted && event.mapped_value == nil && event.reason == nil)
    }
    #expect(simulator.session.parameters.values == parameters)
    #expect(simulator.mock.faders[2] == 64 && simulator.session.bank(.a).faders[2] == 64)
    #expect(simulator.mock.encoders[8] == 127 && simulator.session.bank(.a).encoders[8] == 127)
    #expect(simulator.mock.rings[8] == .position(13))
    #expect(simulator.mock.pressedButtons == [7] && simulator.mock.pushedEncoders == [2])
    let snapshot = try simulator.controls.snapshot(at: 4)
    #expect(snapshot.inputs["a.fader.3"] == .number(64) && snapshot.inputs["a.encoder.9"] == .number(127))
    #expect(snapshot.inputs["a.button.7"] == .bool(true) && snapshot.inputs["a.push.2"] == .bool(true))
    #expect(snapshot.latest_sequence == "4")
    // Feedback on unmapped controls is display intent like on mapped ones.
    _ = try simulator.feedback(feedback(simulator, "a.button.7", .string("on"), kind: "indicator"), at: 5)
    _ = try simulator.feedback(feedback(simulator, "a.encoder.9", .number(0)), at: 5)
    #expect(simulator.mock.buttons[6] == .on && simulator.mock.rings[8] == .position(1))
    #expect(simulator.session.parameters.values == parameters)
}

/// Every declaration is checked against a fresh real Mock/session, with that layer active.
@Test func everyControlDeclaresItsInputEligibilityTruthfully() throws {
    var configuration = CompactSurfaceSimulator.demonstrationConfiguration
    configuration.version = 2
    configuration.parameters += [ParameterDefinition(id: "readonly", name: "Read only", agentWritable: false),
                                 ParameterDefinition(id: "protected", name: "Protected", externallyProtected: true)]
    for layer in CompactLayer.allCases {
        configuration.assignments += [.init(control: .encoder(6), layer: layer, action: .parameter("readonly")),
                                      .init(control: .encoder(7), layer: layer, action: .parameter("protected")),
                                      .init(control: .button(39), layer: layer, action: .set("simulation.arm", 100))]
    }
    let profile = CompactSurfaceSimulator.profile(configuration: configuration)
    for descriptor in profile.controls {
        var simulator = try CompactSurfaceSimulator(instanceID: "eligibility", epoch: "initial", configuration: configuration)
        if descriptor.id.hasPrefix("b.") {
            _ = try simulator.input(input(simulator, "global.layer.b", .bool(true), encoding: "boolean"), at: 0)
        }
        let blocked = descriptor.id.hasSuffix("encoder.6") || descriptor.id.hasSuffix("encoder.7") || descriptor.id.hasSuffix("button.39")
        #expect(descriptor.accepts_input == !blocked)
        let value: JSONValue = descriptor.encoding == .boolean ? .bool(true) : .number(127)
        let before = try simulator.controls.snapshot(at: 1)
        let request = input(simulator, descriptor.id, value, encoding: descriptor.encoding.rawValue)
        if blocked {
            #expect(throws: ControlContractError("permission_denied")) { try simulator.input(request, at: 1) }
            #expect(try simulator.controls.snapshot(at: 1) == before)
        } else {
            #expect(try simulator.input(request, at: 1).disposition == .accepted)
        }
    }
    // `false` is rejected even on an inactive layer, before inactive_layer handling.
    var simulator = try CompactSurfaceSimulator(instanceID: "inactive", epoch: "initial", configuration: configuration)
    for id in ["b.encoder.6", "b.encoder.7", "b.button.39"] {
        let descriptor = try #require(profile.controls.first { $0.id == id })
        let value: JSONValue = descriptor.encoding == .boolean ? .bool(true) : .number(127)
        #expect(throws: ControlContractError("permission_denied")) {
            try simulator.input(input(simulator, id, value, encoding: descriptor.encoding.rawValue), at: 1)
        }
    }
    #expect(try simulator.controls.snapshot(at: 1).latest_sequence == "0")
    #expect(try simulator.input(input(simulator, "b.encoder.9", .number(127)), at: 1).reason == "inactive_layer")
    let defaultProfile = CompactSurfaceSimulator.profile(configuration: CompactSurfaceSimulator.demonstrationConfiguration)
    #expect(defaultProfile.controls.allSatisfy { $0.accepts_input == true })
}

@Test func defaultSimulationMappingRemainsPinned() throws {
    let simulator = try CompactSurfaceSimulator(instanceID: "pin", epoch: "test")
    #expect(simulator.controls.expected.mapping_revision == "2fc51394e3593d7c")
}

@Test func parameterBoundTouchIsMomentaryAcrossReleaseExpiryAndLayers() throws {
    let configuration = SurfaceConfiguration(parameters: [ParameterDefinition(id: "a", name: "a"), ParameterDefinition(id: "b", name: "b")],
                                             assignments: [.init(control: .faderTouch(1), layer: .a, action: .parameter("a")),
                                                           .init(control: .faderTouch(1), layer: .b, action: .parameter("b"))])
    var simulator = try CompactSurfaceSimulator(instanceID: "touch", epoch: "test", configuration: configuration)
    let press = try simulator.input(input(simulator, "a.touch.1", .bool(true), encoding: "boolean", hold: 1), at: 0)
    #expect(press.mapped_value?.finiteNumber == 127)
    #expect(simulator.mock.touchedFaders == [1])
    let release = try simulator.input(input(simulator, "a.touch.1", .bool(false), encoding: "boolean"), at: 0.1)
    #expect(release.mapped_value?.finiteNumber == 0)
    #expect(simulator.mock.touchedFaders.isEmpty)
    _ = try simulator.input(input(simulator, "a.touch.1", .bool(true), encoding: "boolean", hold: 1), at: 0.2)
    _ = try simulator.input(input(simulator, "global.layer.b", .bool(true), encoding: "boolean"), at: 0.3)
    // New-layer binding must not be written when the original layer's hold expires.
    _ = try simulator.input(input(simulator, "b.touch.1", .bool(true), encoding: "boolean"), at: 0.4)
    #expect(simulator.session.parameters.values["a"] == 127 && simulator.session.parameters.values["b"] == 127)
    let expired = try simulator.processHoldExpiries(at: 1.3)
    #expect(expired.count == 1 && expired[0].control_id == "a.touch.1")
    #expect(expired[0].mapped_value?.finiteNumber == 0)
    #expect(simulator.session.parameters.values["a"] == 0 && simulator.session.parameters.values["b"] == 127)
    #expect(simulator.mock.touchedFaders.isEmpty)
    try simulator.reset(epoch: "reset", at: 2)
    #expect(simulator.controls.profile.controls.first { $0.id == "a.touch.1" }?.mapping?.id == "a")
    #expect(simulator.session.parameters.values["a"] == 0)
}

@Test func deniedTouchHasNoHold() throws {
    var configuration = SurfaceConfiguration(parameters: [ParameterDefinition(id: "p", name: "p", externallyProtected: true)],
                                             assignments: [.init(control: .faderTouch(1), layer: .a, action: .parameter("p"))], version: 2)
    for action in [ParameterAction.parameter("p"), .set("p", 1)] {
        configuration.assignments[0].action = action
        let simulator = try CompactSurfaceSimulator(instanceID: "blocked", epoch: "test", configuration: configuration)
        let descriptor = try #require(simulator.controls.profile.controls.first { $0.id == "a.touch.1" })
        #expect(descriptor.accepts_input == false && descriptor.hold == nil)
    }
}

@Test func strictSimulationFieldsMatchCodableKeys() throws {
    func keys(_ value: some Encodable) throws -> Set<String> {
        try Set(#require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any]).keys)
    }
    let parameter = ParameterDefinition(id: "p", name: "p", externallyProtected: false, color: .blue)
    let assignment = ControlAssignment(control: .faderTouch(1), layer: .a, action: .parameter("p"))
    let link = ParameterLink(id: "link", name: "Link", leader: "p", members: ["q"])
    let scene = ParameterScene(id: "scene", name: "Scene", values: ["p": 0])
    #expect(try keys(parameter) == SimulationConfiguration.parameterKeys)
    #expect(try keys(assignment) == SimulationConfiguration.assignmentKeys)
    #expect(try keys(link) == SimulationConfiguration.linkKeys)
    #expect(try keys(scene) == SimulationConfiguration.sceneKeys)
    let configuration = SurfaceConfiguration(parameters: [parameter], assignments: [assignment], version: 2, links: [link], scenes: [scene])
    #expect(try keys(configuration) == SimulationConfiguration.rootKeys)
}
