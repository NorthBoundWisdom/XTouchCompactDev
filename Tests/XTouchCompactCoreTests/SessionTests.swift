import Testing
@testable import XTouchCompactCore

@Test func midiUMPCodecRoundtrip() {
    let messages: [MIDIMessage] = [
        .controlChange(channel: 0, number: 1, value: 127),
        .noteOn(channel: 3, number: 70, velocity: 90),
        .noteOff(channel: 3, number: 70, velocity: 0),
        .programChange(channel: 15, number: 1),
        .pitchBend(channel: 2, value: 16383),
    ]
    for message in messages {
        #expect(MIDI1UMPCodec.decode(MIDI1UMPCodec.encode(message, group: 4)) == message)
    }
    #expect(MIDI1UMPCodec.decode(0x4000_0000) == nil) // 64-bit MIDI 2.0 UMP
    #expect(MIDI1UMPCodec.decode(0x1000_0000) == nil) // System messages
    #expect(MIDI1UMPCodec.decode(0x2090_4000) == .noteOff(channel: 0, number: 64, velocity: 0))
}

@Test func sessionInitializesButNeverAutomaticallyMovesFaders() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    let commands = try session.connect()
    #expect(commands.first == .programChange(channel: 0, number: 0))
    #expect(commands.count == 56) // 1 layer + 16 rings + 39 buttons
    #expect(!commands.contains {
        if case .controlChange(_, 1 ... 9, _) = $0 {
            true
        } else {
            false
        }
    })
    #expect(try session.connect().count == 56)
    #expect(session.bank(.a).faders.allSatisfy { $0 == 0 })
}

@Test func separateApplicationBanksAndExplicitMotorRecall() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.connect()
    _ = try session.setFader(1, value: 100)
    _ = try session.setEncoder(1, value: 127)
    let layerBCommands = try session.selectLayer(.b)
    #expect(layerBCommands.first == .programChange(channel: 0, number: 1))
    #expect(!layerBCommands.contains(.controlChange(channel: 0, number: 1, value: 0)))
    #expect(session.bank(.a).faders[0] == 100)
    #expect(session.bank(.b).faders[0] == 0)
    #expect(session.bank(.a).encoders[0] == 127)
    #expect(session.bank(.b).encoders[0] == 0)
    #expect(try session.setFader(1, value: 55, layer: .a).isEmpty) // inactive bank
    #expect(session.bank(.a).faders[0] == 55)
    let motorCommands = try session.recallFaders()
    #expect(motorCommands.contains(.controlChange(channel: 0, number: 1, value: 0)))
}

@Test func physicalInputAndTouchReconciliation() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .observed114)
    _ = try session.connect()
    let touch = try session.receive([.controlChange(channel: 0, number: 101, value: 127)])
    #expect(touch.inputs.first?.control == .faderTouch(1))
    #expect(try session.setFader(1, value: 112).isEmpty)
    let release = try session.receive([.controlChange(channel: 0, number: 101, value: 0)])
    #expect(release.feedback.contains(.controlChange(channel: 0, number: 1, value: 112)))
    let physical = try session.receive([.controlChange(channel: 0, number: 1, value: 70)])
    #expect(physical.feedback.isEmpty)
    #expect(session.bank(.a).faders[0] == 70)
    #expect(try session.setFader(1, value: 112) == [.controlChange(channel: 0, number: 1, value: 112)])
}

@Test func buttonPressHasSeparateInputAndFeedbackAddress() throws {
    var session = try CompactSession(map: FactoryStandardMap(globalReceiveChannel: 2),
                                     lightProtocol: .observed114)
    _ = try session.connect()
    var config = SurfaceConfiguration.neutral
    config.parameters.append(ParameterDefinition(id: "button", name: "Button", isSwitch: true))
    config.assignments.removeAll { $0.control == .button(1) && $0.layer == .a }
    config.assignments.append(.init(control: .button(1), layer: .a, action: .parameter("button")))
    _ = try session.loadConfiguration(config)
    let pressed = try session.receive([.noteOn(channel: 0, number: 16, velocity: 127)])
    #expect(pressed.inputs.first?.control == .button(1))
    #expect(pressed.feedback.contains(.noteOn(channel: 2, number: 0, velocity: 2)))
    #expect(session.bank(.a).buttons[0])
    let released = try session.receive([.noteOff(channel: 0, number: 16, velocity: 0)])
    #expect(released.inputs.first?.isPressed == false)
    #expect(session.bank(.a).buttons[0]) // momentary note release must not toggle twice
}

@Test func ringFeedbackAfterPhysicalRotation() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.connect()
    let event = try session.receive([.controlChange(channel: 0, number: 10, value: 127)])
    #expect(session.bank(.a).encoders[0] == 127)
    #expect(event.feedback.contains(.controlChange(channel: 0, number: 26, value: 13)))
}

@Test func stalePositionIsNotTreatedAsMotorAcknowledgement() throws {
    var state = try CompactState(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try state.connect()
    _ = state.receive(.controlChange(channel: 0, number: 1, value: 20))
    #expect(try state.setFader(1, value: 80) == [.controlChange(channel: 0, number: 1, value: 80)])
    // The observed 20 became stale when 80 was sent; a newer request for 20 must not
    // be discarded just because the last physical report happened to be 20.
    #expect(try state.setFader(1, value: 20) == [.controlChange(channel: 0, number: 1, value: 20)])
    #expect(try state.setFader(1, value: 20).isEmpty)
}

@Test func transportErrorInvalidatesLastSentFeedback() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.connect()
    #expect(try session.setEncoder(1, value: 40).count == 1)
    #expect(try session.setEncoder(1, value: 40).isEmpty)
    session.invalidateTransportFeedback()
    #expect(try session.setEncoder(1, value: 40).count == 1)
}

@Test func deterministicInputSweepKeepsParametersAndDisplaysWithinBounds() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.connect()
    for turn in 0 ..< 2048 {
        let index = 1 + turn % 16
        let value = UInt8((turn * 31) % 128)
        let raw = UInt8(9 + index)
        let update = try session.receive([.controlChange(channel: 0, number: raw, value: value)])
        #expect(session.bank(.a).encoders[index - 1] == value)
        #expect(update.feedback.allSatisfy {
            if case let .controlChange(_, cc, ringValue) = $0 {
                return cc == UInt8(25 + index) && (1 ... 13).contains(ringValue)
            }
            return false
        })
    }
}

@Test func silentHardwareAttachmentDropsOldTargetsAndObservationsButPreservesTouches() throws {
    let map = try FactoryStandardMap(globalReceiveChannel: 1)
    var session = CompactSession(map: map, lightProtocol: .observed114)
    _ = try session.connect()
    _ = try session.receive([.controlChange(channel: 0, number: 101, value: 127),
                             .controlChange(channel: 0, number: 1, value: 32)])
    #expect(try session.setFader(1, value: 99).isEmpty)
    session.setSafetyTouch(9, touched: true)
    #expect(try session.connect(assertLayer: false).isEmpty)
    #expect(session.state.observedLayer == nil)
    #expect(session.state.observedFader(1) == nil)
    #expect(session.state.isTouched(1) && session.state.isTouched(9))
    #expect(!session.state.isMotorPending(1))
    #expect(try session.receive([.controlChange(channel: 0, number: 101, value: 0)]).feedback.isEmpty)
    session.setSafetyTouch(9, touched: false)
    let explicit = try session.selectLayer(.a)
    #expect(explicit.first == .programChange(channel: 1, number: 0))
    #expect(explicit.count == 56)
    #expect(session.bank(.a).faders[0] == 99) // Target survives, old motor intent does not.
    #expect(try session.setFader(1, value: 99) == [.controlChange(channel: 1, number: 1, value: 99)])
}

@Test func hostOnlyLayerSelectionRetainsEvidenceUntilTransportAcceptance() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.receive([.controlChange(channel: 0, number: 37, value: 42)])
    for layer in [CompactLayer.a, .b, .a] {
        let lights = try session.selectHostLayer(layer)
        #expect(lights.count == 55)
        #expect(!lights.contains {
            if case .programChange = $0 {
                return true
            }; return false
        })
        #expect(session.state.observedLayer == .b)
        #expect(session.state.layerMismatch == (layer == .a))
    }
    #expect(try session.setFader(1, value: 99).isEmpty)
    session.didTransmitLayerAssertion()
    #expect(session.state.observedLayer == nil)
    #expect(try session.setFader(1, value: 99) == [.controlChange(channel: 0, number: 1, value: 99)])
}
