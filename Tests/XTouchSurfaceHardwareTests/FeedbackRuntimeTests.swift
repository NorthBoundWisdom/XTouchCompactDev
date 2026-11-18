import SurfaceControlContracts
import SurfaceDeviceContracts
import Testing
import XTouchCompactCore
@testable import XTouchSurfaceHardware

private func displayFeedbackPlan() throws -> (CompactFeedbackPlan, HardwareEndpointOrigin) {
    var surface = try CompactHardwareSurface(instanceID: "feedback.test", epoch: "initial", configuration: .init(receiveChannel: 0, lightProtocol: .manual), hardwareWriterID: "local", remoteWriterID: "remote")
    try surface.transition(epoch: "connected", connected: true, at: 1)
    _ = try surface.receive(.controlChange(channel: 0, number: 10, value: 0), at: 2)
    let update = ControlFeedback(expected: surface.controls.expected, expectedSequence: surface.controls.discovery().latest_sequence, controlID: "a.button.1", kind: "indicator", value: .string("on"))
    let output = try surface.displayPlan(update, allowed: true, at: 3)
    let origin = HardwareEndpointOrigin(inputID: 11, outputID: 12, connectionGeneration: 7, transportOrigin: "localVirtual")
    return try (HardwareFeedbackRuntime.plan(#require(output.first), index: 0, surface: surface, origin: origin, request: update, writer: "remote", at: 3), origin)
}

@Test func productionHardwareFeedbackPlanKeepsTypedDisplayAndOriginalEndpointFacts() throws {
    let (plan, origin) = try displayFeedbackPlan()
    #expect(plan.source == .hardware)
    #expect(plan.requiredDirections == [.display])
    #expect(plan.endpointEvidence.endpointID == "12")
    #expect(plan.endpointEvidence.deviceID == nil)
    #expect(plan.endpointEvidence.connectionGeneration == 7)
    try HardwareFeedbackRuntime.preflight(plan, current: origin)
}

@Test func productionHardwareFeedbackPreflightRejectsEveryStaleOriginWithoutInventingIdentity() throws {
    let (plan, origin) = try displayFeedbackPlan()
    var generation = origin; generation.connectionGeneration += 1
    var input = origin; input.inputID = 13
    var output = origin; output.outputID = nil
    var transport = origin; transport.transportOrigin = "unknown"
    for current in [generation, input, output, transport, .unavailable] {
        #expect(throws: ControlContractError("invalid_transition")) {
            try HardwareFeedbackRuntime.preflight(plan, current: current)
        }
    }
}
