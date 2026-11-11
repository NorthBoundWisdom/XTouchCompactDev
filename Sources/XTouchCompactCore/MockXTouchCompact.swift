/// Deterministic Standard MIDI device simulation. Physical state is independent of host
/// parameters and sent-command history. RX never synthesizes a TX position acknowledgement.
/// Local redraws model the documented interference, not unverified firmware timing.
public struct MockXTouchCompact: Sendable {
    public let map: FactoryStandardMap
    public let lightProtocol: ButtonLightProtocol
    public private(set) var layer: CompactLayer = .a
    public private(set) var faders: [UInt8] = Array(repeating: 0, count: 9)
    public private(set) var touchedFaders: Set<Int> = []
    public private(set) var encoders: [UInt8] = Array(repeating: 0, count: 16)
    public private(set) var pushedEncoders: Set<Int> = []
    public private(set) var pressedButtons: Set<Int> = []
    public private(set) var buttons: [ButtonLight] = Array(repeating: .off, count: 39)
    public private(set) var rings: [RingDisplay] = Array(repeating: .off, count: 16)
    public private(set) var ringStyles: [RingStyle] = Array(repeating: .single, count: 16)
    public private(set) var ignoredMotorCommands = 0

    public init(map: FactoryStandardMap, lightProtocol: ButtonLightProtocol) {
        self.map = map
        self.lightProtocol = lightProtocol
    }

    public mutating func moveFader(_ index: Int, value: UInt8) throws -> [MIDIMessage] {
        try validate(index, in: 1 ... 9, name: "fader")
        try validate(value)
        faders[index - 1] = value
        return [cc(base: layer == .a ? 1 : 28, index: index, value: value)]
    }

    public mutating func touchFader(_ index: Int, isTouched: Bool) throws -> [MIDIMessage] {
        try validate(index, in: 1 ... 9, name: "fader")
        if isTouched {
            touchedFaders.insert(index)
        } else {
            touchedFaders.remove(index)
        }
        return [cc(base: layer == .a ? 101 : 111, index: index, value: isTouched ? 127 : 0)]
    }

    /// Stock encoders transmit absolute values, even though the physical knob is endless.
    public mutating func turnEncoder(_ index: Int, value: UInt8) throws -> [MIDIMessage] {
        try validate(index, in: 1 ... 16, name: "encoder")
        try validate(value)
        encoders[index - 1] = value
        redrawRing(index)
        return [cc(base: layer == .a ? 10 : 37, index: index, value: value)]
    }

    public mutating func turnEncoder(_ index: Int, delta: Int) throws -> [MIDIMessage] {
        try validate(index, in: 1 ... 16, name: "encoder")
        let value = min(max(Int(encoders[index - 1]) + min(max(delta, -127), 127), 0), 127)
        return try turnEncoder(index, value: UInt8(value))
    }

    public mutating func pushEncoder(_ index: Int, isDown: Bool) throws -> [MIDIMessage] {
        try validate(index, in: 1 ... 16, name: "encoder")
        if isDown {
            pushedEncoders.insert(index)
        } else {
            pushedEncoders.remove(index)
        }
        return [note(base: layer == .a ? 0 : 55, index: index, isDown: isDown)]
    }

    public mutating func pressButton(_ index: Int, isDown: Bool) throws -> [MIDIMessage] {
        try validate(index, in: 1 ... 39, name: "button")
        if isDown {
            pressedButtons.insert(index)
            // Deliberately destructive group redraw exercises the host's reassertion policy.
            if (34 ... 39).contains(index) {
                for other in 34 ... 39 {
                    buttons[other - 1] = .off
                }
            }
        } else {
            pressedButtons.remove(index)
        }
        buttons[index - 1] = isDown ? .on : .off
        return [note(base: layer == .a ? 16 : 71, index: index, isDown: isDown)]
    }

    /// Physical A/B selectors are local: no outbound MIDI event and no motor recall.
    public mutating func selectPhysicalLayer(_ layer: CompactLayer) {
        self.layer = layer
    }

    public mutating func receive(_ messages: [MIDIMessage]) {
        for message in messages {
            receive(message)
        }
    }

    public mutating func receive(_ message: MIDIMessage) {
        switch message {
        case let .controlChange(channel, number, value):
            guard channel == map.globalReceiveChannel, value < 128 else { return }
            switch number {
            case 1 ... 9:
                let index = Int(number)
                guard !touchedFaders.contains(index) else {
                    ignoredMotorCommands += 1
                    return
                }
                faders[index - 1] = value
            case 10 ... 25:
                guard let style = RingStyle(rawValue: value) else { return }
                let index = Int(number) - 9
                ringStyles[index - 1] = style
                redrawRing(index)
            case 26 ... 41:
                let display: RingDisplay
                switch value {
                case 0: display = .off
                case 1 ... 13: display = .position(Int(value))
                case 14 ... 26: display = .blinkingPosition(Int(value) - 13)
                case 27: display = .allOn
                case 28: display = .allBlinking
                default: return
                }
                rings[Int(number) - 26] = display
            default: break // Includes mode changes: simulation only supports Standard MIDI.
            }
        case let .noteOn(channel, number, velocity):
            guard channel == map.globalReceiveChannel, number < 39,
                  let light = ButtonLight.allCases.first(where: { lightProtocol.velocity(for: $0) == velocity })
            else { return }
            buttons[Int(number)] = light
        case let .programChange(channel, number):
            guard channel == map.globalReceiveChannel, number < 2 else { return }
            layer = number == 0 ? .a : .b
        case .noteOff, .pitchBend: break
        }
    }

    private mutating func redrawRing(_ index: Int) {
        rings[index - 1] = .position(CompactSession.ringSegment(for: encoders[index - 1]))
    }

    private func cc(base: UInt8, index: Int, value: UInt8) -> MIDIMessage {
        .controlChange(channel: map.transmitChannel, number: base + UInt8(index - 1), value: value)
    }

    private func note(base: UInt8, index: Int, isDown: Bool) -> MIDIMessage {
        let number = base + UInt8(index - 1)
        return isDown ? .noteOn(channel: map.transmitChannel, number: number, velocity: 127)
            : .noteOff(channel: map.transmitChannel, number: number, velocity: 0)
    }

    private func validate(_ index: Int, in range: ClosedRange<Int>, name: String) throws {
        guard range.contains(index) else { throw CompactError.invalidIndex(name, index) }
    }

    private func validate(_ value: UInt8) throws {
        guard value < 128 else { throw CompactError.invalidMIDIValue(value) }
    }
}
