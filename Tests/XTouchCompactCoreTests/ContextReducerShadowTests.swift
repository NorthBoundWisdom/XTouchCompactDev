import Foundation
import Testing
@testable import XTouchCompactCore

@Test func deferredAndDisplayRegistriesRespectSameContextAndReconnect() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.connect(assertLayer: false)
    _ = try session.receive([.controlChange(channel: 0, number: 101, value: 127), .controlChange(channel: 0, number: 102, value: 127)])
    _ = try session.setParameter("a.Fader.2", value: 44)
    _ = try session.setParameter("a.Fader.1", value: 83)
    _ = try session.setParameter("a.Fader.2", value: 55)
    #expect(session.state.pendingMotorFacts.map(\.index) == [1, 2])
    _ = try session.selectHostLayer(.a)
    #expect(session.state.pendingMotorFacts.isEmpty)
    #expect(session.state.isTouched(1) && session.state.isTouched(2))
    _ = try session.setParameter("a.Fader.1", value: 84)
    #expect(session.state.isMotorPending(1))
    #expect(try session.connect(assertLayer: false).isEmpty)
    #expect(session.state.pendingMotorFacts.isEmpty)
    #expect(try session.connect(assertLayer: false).isEmpty)
    #expect(session.state.isTouched(1) && session.state.observedLayer == nil)
    let ring = try session.setDisplayRing(1, value: 11)
    #expect(!ring.isEmpty)
    _ = try session.receive([.controlChange(channel: 0, number: 10, value: 21)])
    _ = try session.setDisplayButton(34, light: .on)
    _ = try session.receive([.noteOn(channel: 0, number: 49, velocity: 127)])
    session.invalidateTransportFeedback()
    #expect(try !session.setDisplayRing(1, value: 11).isEmpty)
}

@Test func bindingLookupAndRevisionRespectAllPhysicalRoles() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    var configuration = SurfaceConfiguration.neutral
    configuration.assignments += [.init(control: .button(9), layer: .a, action: .set("a.Fader.1", 19)),
                                  .init(control: .button(10), layer: .b, action: .step("b.Fader.1", 2)),
                                  .init(control: .footswitch, layer: .a, action: .resetGroup("Layer A"))]
    let oldGeneration = session.writeAuthorization.bindingGeneration
    _ = try session.loadConfiguration(configuration)
    #expect(session.writeAuthorization.bindingGeneration == oldGeneration + 1)
    for assignment in configuration.assignments {
        #expect(session.parameters.assignment(assignment.control, layer: assignment.layer) == assignment.action)
    }
    #expect(session.parameters.assignment(.expression, layer: .a) == nil)
    let generation = session.writeAuthorization.bindingGeneration
    configuration.parameters[0].name = "metadata edit"
    try session.replaceConfigurationKeepingValues(configuration)
    #expect(session.writeAuthorization.bindingGeneration == generation)
    _ = session.parameters.assignment(.button(9), layer: .a)
    _ = try session.loadConfiguration(configuration)
    #expect(session.writeAuthorization.bindingGeneration == generation + 1)
}

@Test func contextInvalidationRetainsPhysicalMismatchAndOldLayerReleaseSafety() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.connect(assertLayer: false)
    _ = try session.receive([.controlChange(channel: 0, number: 101, value: 127)])
    _ = try session.setParameter("a.Fader.1", value: 91)
    #expect(session.state.isMotorPending(1))
    _ = try session.receive([.controlChange(channel: 0, number: 37, value: 41)])
    #expect(session.state.observedLayer == .b && session.state.layerMismatch)
    #expect(!session.state.isMotorPending(1))
    _ = try session.receive([.controlChange(channel: 0, number: 101, value: 0)])
    #expect(session.state.observedLayer == .b && session.state.layerMismatch)
    let feedback = try session.recallFaders()
    #expect(feedback.isEmpty)
    _ = try session.selectHostLayer(.a)
    #expect(session.state.observedLayer == .b && session.state.layerMismatch)
    #expect(try session.recallFaders().isEmpty)
}

@Test func discardedCandidateDoesNotMutateCanonicalResourcesOrBindings() throws {
    var canonical = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try canonical.receive([.controlChange(channel: 0, number: 101, value: 127)])
    _ = try canonical.setParameter("a.Fader.1", value: 80)
    _ = try canonical.setDisplayRing(1, value: 20)
    let oldGeneration = canonical.writeAuthorization.bindingGeneration
    do {
        var candidate = canonical
        _ = try candidate.selectHostLayer(.b)
        var configuration = SurfaceConfiguration.neutral
        configuration.assignments[0].action = .parameter("a.Fader.2")
        _ = try candidate.loadConfiguration(configuration)
        candidate.invalidateTransportFeedback()
        #expect(candidate.state.pendingMotorFacts.isEmpty)
        #expect(candidate.writeAuthorization.bindingGeneration == oldGeneration + 1)
    }
    // Reads and later mutations must still use the original value oracle, not the discarded branch.
    #expect(canonical.state.isMotorPending(1))
    #expect(canonical.writeAuthorization.bindingGeneration == oldGeneration)
    #expect(canonical.parameters.assignment(.fader(1), layer: .a) == .parameter("a.Fader.1"))
    #expect(try canonical.setDisplayRing(1, value: 20).isEmpty)
    let release = try canonical.receive([.controlChange(channel: 0, number: 101, value: 0)])
    #expect(release.feedback.contains(.controlChange(channel: 0, number: 1, value: 80)))
    #expect(!canonical.state.isMotorPending(1))
}
