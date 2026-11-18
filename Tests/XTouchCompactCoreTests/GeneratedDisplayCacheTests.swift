import Testing
@testable import XTouchCompactCore

@Test func generatedDisplayPreservesStyleRedrawOrderAndInvalidRingRequests() throws {
    var state = try CompactState(map: FactoryStandardMap(transmitChannel: 2, globalReceiveChannel: 5), lightProtocol: .manual)
    #expect(try state.setRing(1, display: .position(7)).map(\.midi1Bytes) == [[0xB5, 0x1A, 7]])
    #expect(try state.setRingStyle(1, style: .fan).map(\.midi1Bytes) == [[0xB5, 0x0A, 2], [0xB5, 0x1A, 7]])
    #expect(try state.setRingStyle(1, style: .fan).isEmpty)
    #expect(try state.setRingStyle(16, style: .trim).map(\.midi1Bytes) == [[0xB5, 0x19, 4]])

    #expect(throws: CompactError.invalidDisplayPosition(0)) { try state.setRing(1, display: .position(0)) }
    #expect(throws: CompactError.invalidDisplayPosition(14)) { try state.setRing(1, display: .blinkingPosition(14)) }
    #expect(throws: CompactError.invalidIndex("button", 40)) { try state.setButton(40, light: .on) }
    #expect(throws: CompactError.invalidIndex("encoder", 17)) { try state.setRingStyle(17, style: .fan) }
    #expect(state.desiredRing(1) == .position(7) && state.generatedRingProposal(1) == .position(7))
    #expect(try state.setRing(1, display: .position(7)).isEmpty)

    _ = try state.setRing(2, display: .position(3))
    _ = try state.setButton(39, light: .on)
    _ = try state.setButton(1, light: .on)
    state.invalidateNonMotorFeedback()
    #expect(try state.restoreNonMotorFeedback().map(\.midi1Bytes) == [
        [0xB5, 0x0A, 2], [0xB5, 0x1A, 7], [0xB5, 0x19, 4],
        [0xB5, 0x1B, 3], [0x95, 0, 1], [0x95, 38, 1],
    ])
}

@Test func generatedDisplaySeparatesActualInvalidationFromMetadataAndHostLayerChanges() throws {
    var state = try CompactState(map: FactoryStandardMap(transmitChannel: 2, globalReceiveChannel: 5), lightProtocol: .manual)
    _ = try state.setRing(1, display: .position(7))
    _ = try state.setRing(2, display: .position(8))
    _ = try state.setButton(1, light: .on)
    for index in 34 ... 39 {
        _ = try state.setButton(index, light: .on)
    }

    state.setResourceAuthorization(.init(routeGeneration: 14, bindingGeneration: 3))
    state.selectHostLayer(.a)
    #expect(try state.setRing(1, display: .position(7)).isEmpty)
    #expect(try state.setButton(1, light: .on).isEmpty)
    #expect(state.receive(.controlChange(channel: 2, number: 10, value: 1))?.control == .encoder(1))
    #expect(try state.setRing(1, display: .position(7)).map(\.midi1Bytes) == [[0xB5, 0x1A, 7]])
    #expect(try state.setRing(2, display: .position(8)).isEmpty)

    #expect(state.receive(.noteOn(channel: 2, number: 49, velocity: 127))?.control == .button(34))
    let redraw = try (34 ... 39).flatMap { try state.setButton($0, light: .on) }
    #expect(redraw.map(\.midi1Bytes) == (33 ... 38).map { [0x95, UInt8($0), 1] })
    #expect(try state.setButton(1, light: .on).isEmpty)
    #expect(state.receive(.noteOff(channel: 2, number: 16, velocity: 0))?.isPressed == false)
    #expect(try state.setButton(1, light: .on).map(\.midi1Bytes) == [[0x95, 0, 1]])

    var copy = try state.reconfigured(map: FactoryStandardMap(transmitChannel: 2, globalReceiveChannel: 6), lightProtocol: .observed114)
    #expect(try copy.connect(assertLayer: false).isEmpty)
    #expect(try copy.setButton(1, light: .on).map(\.midi1Bytes) == [[0x96, 0, 2]])
    #expect(try state.setButton(1, light: .on).isEmpty)
}
