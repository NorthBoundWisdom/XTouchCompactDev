import Foundation
import Testing
@testable import XTouchCompactCore

private func replayCapture(_ inputs: [[String: Any]], mode: Bool = true, unknownProfile: Bool = false) throws -> RecordedCapture {
    let session: [String: Any] = ["hardwareMode": mode, "configuredTransmitChannel": 1,
                                  "configuredGlobalReceiveChannel": unknownProfile ? NSNull() : 2,
                                  "ledProtocol": unknownProfile ? NSNull() : "observed114",
                                  "connectionGeneration": 0, "connectedInput": ["id": 1], "connectedOutput": ["id": 2]]
    var rows: [[String: Any]] = [["kind": "capture-start", "schemaVersion": 1, "session": session]]
    for (index, fields) in inputs.enumerated() {
        var row: [String: Any] = ["kind": "event", "sequence": index + 1, "source": "hardware", "hardwareMode": mode,
                                  "hostLayer": "a", "transmitChannel": 1, "globalReceiveChannel": 2, "ledProtocol": "observed114", "ignored": false]
        row.merge(fields) { _, new in new }
        rows.append(row)
    }
    rows.append(["kind": "capture-end", "eventCount": inputs.count])
    var data = Data()
    for row in rows {
        try data.append(JSONSerialization.data(withJSONObject: row)); data.append(10)
    }
    return try RecordedCapture(data: data)
}

private func input(_ bytes: [Int], layer: String = "a", source: String = "hardware") -> [String: Any] {
    ["rawMIDI1Bytes": bytes, "direction": "IN", "delivery": "received", "hostLayer": layer, "source": source]
}

@Test func replayRestoresEveryFactoryInputOnBothLayersWithoutInventingCyclesOrActions() throws {
    var events: [[String: Any]] = []
    for b in [false, true] {
        let layer = b ? "b" : "a"
        for index in 1 ... 9 {
            events += [input([176, (b ? 110 : 100) + index, 127], layer: layer),
                       input([176, (b ? 27 : 0) + index, index * 10], layer: layer),
                       input([176, (b ? 110 : 100) + index, 0], layer: layer)]
        }
        for index in 0 ..< 16 {
            events += [input([176, (b ? 37 : 10) + index, index * 7], layer: layer),
                       input([144, (b ? 55 : 0) + index, 127], layer: layer), input([128, (b ? 55 : 0) + index, 0], layer: layer)]
        }
        for index in 0 ..< 39 {
            events += [input([144, (b ? 71 : 16) + index, 127], layer: layer), input([128, (b ? 71 : 16) + index, 0], layer: layer)]
        }
        events += [input([176, b ? 63 : 26, 75], layer: layer), input([176, b ? 64 : 27, 127], layer: layer), input([176, b ? 64 : 27, 0], layer: layer)]
    }
    var replay = try RecordedCaptureReplay(capture: replayCapture(events))
    while try replay.step() {}
    #expect(replay.cursor == events.count && replay.inputsReplayed == events.count)
    #expect(replay.mock.faders == (1 ... 9).map { UInt8($0 * 10) })
    #expect(replay.mock.encoders == (0 ..< 16).map { UInt8($0 * 7) })
    #expect(replay.mock.expression == 75 && !replay.mock.footswitchDown)
    #expect(replay.mock.touchedFaders.isEmpty && replay.mock.pushedEncoders.isEmpty && replay.mock.pressedButtons.isEmpty)
    #expect(replay.mock.ignoredMotorCommands == 0 && replay.mock.firmwareFaderCycles == 0)
    #expect(replay.ignoredActionCount > 0) // Count only; the pure replay cannot invoke an Agent.
}

@Test func recordedMotorAndLayerOutputsAreSkippedRatherThanExecuted() throws {
    let events = [input([176, 1, 23]),
                  ["rawMIDI1Bytes": [177, 1, 99], "direction": "OUT", "delivery": "sent"],
                  ["rawMIDI1Bytes": [193, 1], "direction": "OUT", "delivery": "sent"]]
    var replay = try RecordedCaptureReplay(capture: replayCapture(events))
    while try replay.step() {}
    #expect(replay.mock.faders[0] == 23)
    #expect(replay.mock.firmwareFaderCycles == 0)
    #expect(replay.recordedOutputsSkipped == 2 && replay.generatedFeedbackCount == 0)
    #expect(replay.session.state.observedLayer == nil) // Recorded assertion invalidates evidence only.
}

@Test func replayTestWriteDefersUntilReleaseAndResetIsDeterministic() throws {
    let capture = try replayCapture([input([176, 101, 127]), input([176, 1, 30]), input([176, 101, 0])])
    var replay = try RecordedCaptureReplay(capture: capture)
    try replay.step(); try replay.step(); try replay.setFader(1, value: 90)
    #expect(replay.session.state.isMotorPending(1) && replay.mock.faders[0] == 30)
    try replay.step()
    #expect(replay.mock.faders[0] == 90 && !replay.session.state.isMotorPending(1))
    #expect(replay.generatedFeedbackCount == 1)
    #expect(try replay.step() == false)
    #expect(replay.session.state.observedFader(1) == 30) // Simulated command is not an input acknowledgement.
    try replay.reset()
    #expect(replay.cursor == 0 && replay.mock.faders[0] == 0 && replay.session.state.observedFader(1) == nil)
    while try replay.step() {}
    #expect(replay.mock.faders[0] == 30 && replay.generatedFeedbackCount == 0)
}

@Test func replayMismatchReconnectAndProfileChangeCannotReplayOldTargets() throws {
    var mismatch = try RecordedCaptureReplay(capture: replayCapture([input([176, 111, 127]), input([176, 111, 0])]))
    try mismatch.step(); try mismatch.setFader(1, value: 90); try mismatch.step()
    #expect(mismatch.session.state.layerMismatch)
    #expect(mismatch.mock.faders[0] == 0 && mismatch.generatedFeedbackCount == 0)
    for profile in [false, true] {
        let change: [String: Any] = profile ? ["transmitChannel": 5] : ["connection": ["generation": 1, "connectedInput": ["id": 1], "connectedOutput": ["id": 2]]]
        var release = input([profile ? 180 : 176, 101, 0])
        if profile {
            release["transmitChannel"] = 5
        }
        var replay = try RecordedCaptureReplay(capture: replayCapture([input([176, 101, 127]), change, release]))
        try replay.step(); try replay.setFader(1, value: 100); try replay.step()
        #expect(replay.session.state.isTouched(1) && !replay.session.state.isMotorPending(1))
        try replay.step()
        #expect(replay.mock.faders[0] == 0 && replay.generatedFeedbackCount == 0)
        #expect(replay.boundaryCount > 0)
    }
}

@Test func replayKeepsInactiveHardwareSafetyAndUnknownFactsSeparateFromMock() throws {
    let capture = try replayCapture([input([176, 101, 127]), input([176, 1, 77], source: "mock")], mode: false, unknownProfile: true)
    var replay = try RecordedCaptureReplay(capture: capture)
    #expect(replay.usesFallbackProfile && capture.session.receiveChannel == nil && capture.session.lightProtocol == nil)
    #expect(replay.session.state.map.globalReceiveChannel == 0) // Declared simulation default, not a device fact.
    try replay.step()
    #expect(replay.inputsReplayed == 0 && replay.session.state.isTouched(1))
    #expect(replay.lastDisposition == .safetyTouch)
    try replay.step()
    #expect(replay.inputsReplayed == 1 && replay.mock.faders[0] == 77)
    #expect(replay.capture.session.receiveChannel == nil)
    #expect(throws: CompactError.invalidMIDIValue(128)) { try replay.setFader(1, value: 128) }
}

@Test func capturedInputProfileChangesPreserveMockPedals() throws {
    var replay = try RecordedCaptureReplay(capture: replayCapture([input([176, 26, 65]), input([176, 27, 127]), ["transmitChannel": 5]]))
    while try replay.step() {}
    #expect(replay.mock.expression == 65 && replay.mock.footswitchDown)
}

@Test func capturedInputEntryRejectsFeedbackAndInvalidInputWithoutChangingMockState() throws {
    let map = try FactoryStandardMap(transmitChannel: 4, globalReceiveChannel: 11)
    var mock = MockXTouchCompact(map: map, lightProtocol: .observed114)
    _ = try mock.moveFader(1, value: 23)
    mock.selectPhysicalLayer(.b)
    for message in [MIDIMessage.programChange(channel: 11, number: 0),
                    .controlChange(channel: 0, number: 101, value: 127),
                    .controlChange(channel: 4, number: 1, value: 255)]
    {
        #expect(try mock.applyCapturedInput(message) == nil)
        #expect(mock.faders[0] == 23 && mock.layer == .b && mock.touchedFaders.isEmpty)
        #expect(mock.firmwareFaderCycles == 1)
    }
    let button = try mock.applyCapturedInput(.noteOn(channel: 4, number: 71, velocity: 127))
    #expect(button?.control == .button(1) && mock.pressedButtons == [1])
    #expect(mock.firmwareFaderCycles == 1)
}
