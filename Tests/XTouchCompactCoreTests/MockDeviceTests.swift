import Testing
@testable import XTouchCompactCore

@Test func mockGesturesUseEveryFactoryTXAddress() throws {
    let map = try FactoryStandardMap(transmitChannel: 4, globalReceiveChannel: 11)
    var mock = MockXTouchCompact(map: map, lightProtocol: .manual)
    for layer in CompactLayer.allCases {
        mock.selectPhysicalLayer(layer)
        for i in 1 ... 9 {
            let move = try mock.moveFader(i, value: 73)
            #expect(move == [.controlChange(channel: 4, number: UInt8((layer == .a ? 1 : 28) + i - 1), value: 73)])
            #expect(map.decode(move[0], layer: layer)?.control == .fader(i))
            for pressed in [true, false] {
                let touch = try mock.touchFader(i, isTouched: pressed)
                #expect(touch == [.controlChange(channel: 4, number: UInt8((layer == .a ? 101 : 111) + i - 1),
                                                 value: pressed ? 127 : 0)])
                #expect(map.decode(touch[0], layer: layer)?.isPressed == pressed)
            }
        }
        for i in 1 ... 16 {
            let turn = try mock.turnEncoder(i, value: 99)
            #expect(turn == [.controlChange(channel: 4, number: UInt8((layer == .a ? 10 : 37) + i - 1), value: 99)])
            #expect(map.decode(turn[0], layer: layer)?.control == .encoder(i))
            let note = UInt8((layer == .a ? 0 : 55) + i - 1)
            #expect(try mock.pushEncoder(i, isDown: true) == [.noteOn(channel: 4, number: note, velocity: 127)])
            #expect(mock.pushedEncoders.contains(i))
            #expect(try mock.pushEncoder(i, isDown: false) == [.noteOff(channel: 4, number: note, velocity: 0)])
            #expect(!mock.pushedEncoders.contains(i))
        }
        for i in 1 ... 39 {
            let note = UInt8((layer == .a ? 16 : 71) + i - 1)
            #expect(try mock.pressButton(i, isDown: true) == [.noteOn(channel: 4, number: note, velocity: 127)])
            #expect(mock.pressedButtons.contains(i))
            #expect(try mock.pressButton(i, isDown: false) == [.noteOff(channel: 4, number: note, velocity: 0)])
            #expect(!mock.pressedButtons.contains(i))
        }
    }
}

@Test func mockReceivesFeedbackOnGlobalRXIndependentOfLayerAndTX() throws {
    let map = try FactoryStandardMap(transmitChannel: 4, globalReceiveChannel: 11)
    var mock = MockXTouchCompact(map: map, lightProtocol: .manual)
    for layer in CompactLayer.allCases {
        mock.receive(map.selectLayer(layer))
        #expect(mock.layer == layer)
        for i in 1 ... 9 {
            try mock.receive(map.motorPosition(fader: i, value: 87))
            #expect(mock.faders[i - 1] == 87)
        }
        for i in 1 ... 16 {
            for style in RingStyle.allCases {
                try mock.receive(map.encoderRingStyle(encoder: i, style: style))
                #expect(mock.ringStyles[i - 1] == style)
            }
            let displays: [RingDisplay] = [.off, .allOn, .allBlinking]
                + (1 ... 13).map { .position($0) } + (1 ... 13).map { .blinkingPosition($0) }
            for display in displays {
                try mock.receive(map.encoderRingValue(encoder: i, display: display))
                #expect(mock.rings[i - 1] == display)
            }
        }
    }
    mock.receive(.controlChange(channel: 4, number: 1, value: 12))
    mock.receive(.programChange(channel: 4, number: 0))
    #expect(mock.faders[0] == 87)
    #expect(mock.layer == .b)
}

@Test(arguments: [ButtonLightProtocol.manual, .observed114])
func mockConsumesBothLEDVelocityProtocols(_ variant: ButtonLightProtocol) throws {
    let map = try FactoryStandardMap(globalReceiveChannel: 8)
    var mock = MockXTouchCompact(map: map, lightProtocol: variant)
    for i in 1 ... 39 {
        for light in ButtonLight.allCases {
            try mock.receive(map.buttonLight(button: i, light: light, style: variant))
            #expect(mock.buttons[i - 1] == light)
        }
    }
    mock.receive(.noteOn(channel: 0, number: 0, velocity: 0))
    mock.receive(.noteOn(channel: 8, number: 0, velocity: 127))
    #expect(mock.buttons[0] == .blink)
}

@Test func mockRejectsMotorCommandsWhileTouchedAndCountsThem() throws {
    let map = try FactoryStandardMap(globalReceiveChannel: 2)
    var mock = MockXTouchCompact(map: map, lightProtocol: .manual)
    for i in 1 ... 9 {
        _ = try mock.moveFader(i, value: 23)
        _ = try mock.touchFader(i, isTouched: true)
        try mock.receive(map.motorPosition(fader: i, value: 99))
        #expect(mock.faders[i - 1] == 23)
        _ = try mock.touchFader(i, isTouched: false)
        try mock.receive(map.motorPosition(fader: i, value: 99))
        #expect(mock.faders[i - 1] == 99)
    }
    #expect(mock.ignoredMotorCommands == 9)
}

@Test func mockSessionTouchSoftwareWriteReleaseClosedLoop() throws {
    let map = try FactoryStandardMap(transmitChannel: 3, globalReceiveChannel: 9)
    var mock = MockXTouchCompact(map: map, lightProtocol: .observed114)
    var session = CompactSession(map: map, lightProtocol: .observed114)
    try mock.receive(session.connect())
    for layer in CompactLayer.allCases {
        try mock.receive(session.selectLayer(layer))
        for i in 1 ... 9 {
            var update = try session.receive(mock.touchFader(i, isTouched: true))
            mock.receive(update.feedback)
            update = try session.receive(mock.moveFader(i, value: 31))
            #expect(update.feedback.isEmpty)
            #expect(session.bank(layer).faders[i - 1] == 31)
            let write = try session.setFader(i, value: 106)
            #expect(write.isEmpty)
            mock.receive(write)
            #expect(mock.faders[i - 1] == 31)
            update = try session.receive(mock.touchFader(i, isTouched: false))
            #expect(try update.feedback == [map.motorPosition(fader: i, value: 106)])
            mock.receive(update.feedback)
            #expect(mock.faders[i - 1] == 106)
            #expect(try session.receive(mock.touchFader(i, isTouched: false)).feedback.isEmpty)
        }
    }
    #expect(mock.ignoredMotorCommands == 0)
}

@Test func mockLocalRedrawIsRestoredThroughSessionFeedback() throws {
    let map = try FactoryStandardMap()
    var mock = MockXTouchCompact(map: map, lightProtocol: .manual)
    var session = CompactSession(map: map, lightProtocol: .manual)
    try mock.receive(session.connect())
    try mock.receive(map.encoderRingValue(encoder: 1, display: .allBlinking))
    let rotation = try mock.turnEncoder(1, value: 127)
    #expect(mock.rings[0] == .position(13))
    try mock.receive(session.receive(rotation).feedback)
    #expect(session.bank(.a).encoders[0] == 127)
    #expect(mock.rings[0] == .position(13))

    try mock.receive(session.toggleButton(35))
    let press = try mock.pressButton(34, isDown: true)
    #expect(mock.buttons[34] == .off) // Local transport group redraw erased button 35.
    try mock.receive(session.receive(press).feedback)
    #expect(mock.buttons[33] == .on)
    #expect(mock.buttons[34] == .on)
    let release = try mock.pressButton(34, isDown: false)
    #expect(mock.buttons[33] == .off)
    try mock.receive(session.receive(release).feedback)
    #expect(mock.buttons[33] == .on)
    #expect(session.bank(.a).buttons[33]) // Release does not toggle the parameter again.
}

@Test func mockLayerSelectorsDoNotGenerateEventsOrMoveMotors() throws {
    let map = try FactoryStandardMap()
    var mock = MockXTouchCompact(map: map, lightProtocol: .manual)
    var session = CompactSession(map: map, lightProtocol: .manual)
    _ = try mock.moveFader(1, value: 66)
    try mock.receive(session.connect())
    #expect(mock.faders[0] == 66)
    mock.selectPhysicalLayer(.b)
    #expect(session.state.layer == .a) // Host cannot discover a local selector without MIDI.
    #expect(mock.layer == .b)
    #expect(mock.faders[0] == 66)
    try mock.receive(session.connect())
    #expect(mock.layer == .a)
    try mock.receive(session.selectLayer(.b))
    #expect(mock.layer == .b)
    #expect(mock.faders[0] == 66)
}

@Test func mockValidatesGesturesAndClampsEncoderDeltas() throws {
    var mock = try MockXTouchCompact(map: FactoryStandardMap(), lightProtocol: .manual)
    #expect(throws: CompactError.invalidIndex("fader", 0)) { try mock.moveFader(0, value: 20) }
    #expect(throws: CompactError.invalidIndex("fader", 10)) { try mock.touchFader(10, isTouched: true) }
    #expect(throws: CompactError.invalidIndex("encoder", 17)) { try mock.turnEncoder(17, value: 20) }
    #expect(throws: CompactError.invalidIndex("encoder", -1)) { try mock.pushEncoder(-1, isDown: true) }
    #expect(throws: CompactError.invalidIndex("button", 40)) { try mock.pressButton(40, isDown: true) }
    #expect(throws: CompactError.invalidMIDIValue(128)) { try mock.moveFader(1, value: 128) }
    #expect(throws: CompactError.invalidMIDIValue(255)) { try mock.turnEncoder(1, value: 255) }
    _ = try mock.turnEncoder(1, delta: .max)
    #expect(mock.encoders[0] == 127)
    _ = try mock.turnEncoder(1, delta: .min)
    #expect(mock.encoders[0] == 0)
    mock.receive(.controlChange(channel: 0, number: 1, value: 255))
    mock.receive(.controlChange(channel: 0, number: 10, value: 5))
    mock.receive(.controlChange(channel: 0, number: 26, value: 29))
    mock.receive(.programChange(channel: 0, number: 2))
    mock.receive(.noteOff(channel: 0, number: 0, velocity: 0))
    mock.receive(.pitchBend(channel: 0, value: 1000))
    #expect(mock.faders[0] == 0)
    #expect(mock.ringStyles[0] == .single)
    #expect(mock.rings[0] == .position(1))
    #expect(mock.layer == .a)
}
