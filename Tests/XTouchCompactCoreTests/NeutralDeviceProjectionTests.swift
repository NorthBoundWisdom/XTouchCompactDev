import Foundation
import SurfaceDeviceContracts
import Testing
@testable import XTouchCompactCore

private func neutralFixtureContext(_ layer: CompactLayer) throws -> DeviceContext {
    try CompactNeutralProjection.context(instanceID: "fixture", routeGeneration: 3, bindingGeneration: 7,
                                         hostLayer: layer, knownHardwareLayer: nil)
}

@Test func neutralPhysicalRolesStayStableAcrossLayersWhileLogicalTargetsAndContextsDiffer() throws {
    let endpoint = try EndpointProvenance(endpointID: nil, deviceID: nil, connectionGeneration: 3, transportOrigin: .unknown)
    let a = try CompactNeutralProjection.input(.init(control: .encoder(1), layer: .a, value: 42), context: neutralFixtureContext(.a), endpoint: endpoint, source: .hardware, at: 4)
    let b = try CompactNeutralProjection.input(.init(control: .encoder(1), layer: .b, value: 42), context: neutralFixtureContext(.b), endpoint: endpoint, source: .hardware, at: 4)
    #expect(a.elementID == b.elementID)
    #expect(a.context != b.context)
    #expect(CompactNeutralProjection.logicalTargetID(.encoder(1), layer: .a) != CompactNeutralProjection.logicalTargetID(.encoder(1), layer: .b))
    #expect(CompactNeutralProjection.elementID(.encoder(1)) != CompactNeutralProjection.elementID(.encoderPush(1)))
    #expect(a.context.id.contains("device-layer=unknown"))
    #expect(a.endpoint.endpointID == nil && a.endpoint.deviceID == nil)
}

@Test func neutralLayerEffectRequiresManagementAndMechanismWithoutADeviceSafetySwitch() throws {
    let map = try FactoryStandardMap()
    let endpoint = try EndpointProvenance(endpointID: "fixture-output", deviceID: nil, connectionGeneration: 3, transportOrigin: .localVirtual)
    let effect = try CompactNeutralProjection.feedback(map.selectLayer(.b), map: map, hostLayer: .a,
                                                       effectID: "layer-request", context: neutralFixtureContext(.a), endpoint: endpoint, source: .simulation, at: 5)
    #expect(effect.classification == .management)
    #expect(effect.requiredDirections == [.management, .mechanism])
    #expect(effect.affectedElements == Set((1 ... 9).map { CompactNeutralProjection.elementID(.fader($0)) }))
    #expect(effect.targetID == "device.layer")
}

@Test func neutralCapabilitiesUseOneRealProtocolModeAndTheHardwareServiceCannotDeclareMotion() throws {
    let console = try CompactNeutralProjection.capabilities(), service = try CompactNeutralProjection.capabilities(hardwareService: true)
    #expect(console.modes.map(\.id) == ["standard-midi"])
    #expect(service.modes.map(\.id) == ["standard-midi"])
    #expect(console.modes[0].elements.count == 91)
    #expect(Set(console.modes[0].elements.map(\.elementID)).count == 91)
    #expect(console.modes[0].elements.map(\.elementID) == service.modes[0].elements.map(\.elementID))
    #expect(service.modes[0].elements.flatMap(\.effects).allSatisfy { !$0.requiredDirections.contains(.mechanism) && !$0.requiredDirections.contains(.management) })
    #expect(console.modes[0].elements.flatMap(\.effects).contains { $0.requiredDirections == [.management, .mechanism] })
}

@Test func neutralObservationNeedsActualInputAndRejectsNonFiniteInjectedTime() throws {
    let endpoint = try EndpointProvenance(endpointID: nil, deviceID: nil, connectionGeneration: 3, transportOrigin: .remoteVirtual)
    let context = try neutralFixtureContext(.a)
    #expect(throws: DeviceContractError.nonFiniteValue) {
        try CompactNeutralProjection.input(.init(control: .fader(1), layer: .a, value: 0), context: context, endpoint: endpoint, source: .hardware, at: .nan)
    }
    let input = try CompactNeutralProjection.input(.init(control: .faderTouch(1), layer: .a, value: 127, isPressed: true), context: context, endpoint: endpoint, source: .hardware, at: 3)
    let observation = try CompactNeutralProjection.observation(input)
    #expect(observation.evidence == .deviceReport && observation.state == .observed)
    #expect(input.kind == .contactBegan && input.value == .flag(true))
    #expect(input.source == .hardware && input.endpoint.transportOrigin == .remoteVirtual)
}

private func plannedFixture(_ id: String, generation: String = "generation.a") throws -> CompactPlannedProvenance {
    try .init(id: id, source: .hardware,
              endpoint: .init(endpointID: "output", deviceID: nil, connectionGeneration: 3, transportOrigin: .unknown),
              context: .init(id: "known.adapter.context", generation: generation, mappingRevision: nil), origin: .remote, at: 5)
}

@Test func plannedProvenanceFollowsTwoNativeSlotsCoalescingConsumptionAndUnknownWithoutChangingBytes() throws {
    var state = try CompactState(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = state.receive(.controlChange(channel: 0, number: 101, value: 127))
    _ = state.receive(.controlChange(channel: 0, number: 102, value: 127))
    let a = try plannedFixture("intent.a"), b = try plannedFixture("intent.b")
    #expect(try state.setFader(1, value: 80, provenance: a).isEmpty)
    #expect(try state.setFader(2, value: 80, provenance: a).isEmpty)
    #expect(state.pendingMotorFacts.count == 2)
    _ = try state.setFader(1, value: 80, provenance: b)
    #expect(state.pendingMotorFacts.first { $0.index == 1 }?.provenance == b)
    #expect(state.pendingMotorFacts.first { $0.index == 2 }?.provenance == a)
    _ = try state.setFader(1, value: 80) // Missing caller provenance replaces an old known origin with genuine unknown.
    #expect(state.pendingMotorFacts.first { $0.index == 1 }?.provenance == nil)
    _ = state.receive(.controlChange(channel: 0, number: 101, value: 0))
    #expect(try state.reconcileReleasedFader(1) == [.controlChange(channel: 0, number: 1, value: 80)])
    #expect(state.producedMotorProvenance(1) == nil)
    _ = state.receive(.controlChange(channel: 0, number: 102, value: 0))
    #expect(try state.reconcileReleasedFader(2) == [.controlChange(channel: 0, number: 2, value: 80)])
    #expect(state.producedMotorProvenance(2) == a)
    #expect(state.pendingMotorFacts.isEmpty)
}

@Test func identicalMotorBytesWithDifferentCapturedScopesCannotConsumeAnOldIntent() throws {
    let map = try FactoryStandardMap(), a = try plannedFixture("a"), b = try plannedFixture("b", generation: "generation.b")
    let pending = CompactPendingMotorFact(index: 1, target: 80, observed: nil, touched: true, provenance: a)
    let sameBytes = try map.motorPosition(fader: 1, value: 80)
    #expect(try pending.matchesProducedPlan(sameBytes, provenance: a, map: map))
    #expect(try !pending.matchesProducedPlan(sameBytes, provenance: b, map: map))
    #expect(try !pending.matchesProducedPlan(sameBytes, provenance: nil, map: map))
    let unknown = CompactPendingMotorFact(index: 1, target: 80, observed: nil, touched: true, provenance: nil)
    #expect(try !unknown.matchesProducedPlan(sameBytes, provenance: nil, map: map))
}

@Test func nativeContextRevocationClearsPlannedSidecarsAndKeepsTouchProtection() throws {
    var state = try CompactState(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = state.receive(.controlChange(channel: 0, number: 101, value: 127))
    _ = try state.setFader(1, value: 80, provenance: plannedFixture("old"))
    #expect(state.pendingMotorFacts.count == 1)
    state.selectHostLayer(.b)
    #expect(state.pendingMotorFacts.isEmpty && state.producedMotorProvenance(1) == nil)
    #expect(state.isTouched(1))
    #expect(throws: CompactError.fadersTouched) { try state.validateLayerAssertion() }
}
