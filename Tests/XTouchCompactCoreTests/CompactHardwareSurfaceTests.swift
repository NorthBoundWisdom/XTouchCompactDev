import SurfaceControlContracts
import Testing
@testable import XTouchCompactCore

@Test func faderHardwareFeedbackReturnsUnsupportedAndProducesZeroMessages() throws {
    var host = try CompactHardwareSurface(instanceID: "test", epoch: "initial", configuration: .init(receiveChannel: 1, lightProtocol: .observed114), hardwareWriterID: "device", remoteWriterID: "remote")
    try host.transition(epoch: "connected", connected: true, at: 0)
    _ = try host.receive(.controlChange(channel: 0, number: 28, value: 100), at: 1)
    let before = try host.controls.snapshot(at: 2)
    let update = ControlFeedback(expected: host.controls.expected, controlID: "b.fader.1", kind: "value", value: .number(64))
    var sent: [HardwareDisplayMessage] = []
    do { sent += try host.displayPlan(update, allowed: true, at: 2); Issue.record("fader feedback must fail") }
    catch let error as ControlContractError { #expect(error.code == "unsupported_feedback") }
    #expect(sent.isEmpty)
    let after = try host.controls.snapshot(at: 2)
    #expect(before == after)
}

@Test func recordedFVLayerBPositionAndTouchStayIndependentAndNeverCreateOutput() throws {
    var host = try CompactHardwareSurface(instanceID: "test", epoch: "initial", configuration: .init(receiveChannel: 1, lightProtocol: .observed114), hardwareWriterID: "device", remoteWriterID: "remote")
    try host.transition(epoch: "connected", connected: true, at: 0)
    let positionEvent = try host.receive(.controlChange(channel: 0, number: 28, value: 127), at: 1)
    let position = try #require(positionEvent)
    #expect(position.control_id == "b.fader.1")
    #expect(position.value == .number(127))
    #expect(position.source.rawValue == "hardware" && position.origin.rawValue == "hardware")
    let touchEvent = try host.receive(.controlChange(channel: 0, number: 111, value: 127), at: 2)
    let touch = try #require(touchEvent)
    #expect(touch.control_id == "b.touch.1" && touch.value == .bool(true))
    let releaseEvent = try host.receive(.controlChange(channel: 0, number: 111, value: 0), at: 3)
    let release = try #require(releaseEvent)
    #expect(release.value == .bool(false))
    try host.transition(epoch: "gone", connected: false, at: 4)
    try host.transition(epoch: "back", connected: true, at: 5)
    let snapshot = try host.controls.snapshot(at: 5)
    #expect(snapshot.inputs.isEmpty && snapshot.feedback.isEmpty)
    #expect(host.observedLayer == nil)
}
