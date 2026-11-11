import Foundation

/// Host-owned state and feedback policy. Hardware commands are returned as messages;
/// the caller routes them through its CoreMIDI transport. No physical motor is used by tests.
public struct CompactState: Sendable {
    public let map: FactoryStandardMap
    public let lightProtocol: ButtonLightProtocol
    public private(set) var layer: CompactLayer = .a

    public private(set) var observedLayer: CompactLayer?
    public var layerMismatch: Bool {
        observedLayer.map { $0 != layer } ?? false
    }

    private var safetyTouches: Set<Int> = []
    private var touchedFaders: Set<Int> = []
    private var desiredFader: [Int: UInt8] = [:]
    private var observedFaders: [Int: UInt8] = [:]
    private var lastMotorCommands: [Int: UInt8] = [:]
    // A position report becomes stale as soon as the host commands a motor movement.
    private var observedIsCurrent: Set<Int> = []
    private var pendingMotor: Set<Int> = []
    private var desiredButtons: [Int: ButtonLight] = [:]
    private var lastSentButtons: [Int: ButtonLight] = [:]
    private var desiredRings: [Int: RingDisplay] = [:]
    private var lastSentRings: [Int: RingDisplay] = [:]
    private var desiredStyles: [Int: RingStyle] = [:]
    private var lastSentStyles: [Int: RingStyle] = [:]
    private var pressedButtons: Set<Int> = []
    private var pushedEncoders: Set<Int> = []

    public init(map: FactoryStandardMap, lightProtocol: ButtonLightProtocol) {
        self.map = map
        self.lightProtocol = lightProtocol
    }

    /// Last actual TX position report, possibly stale after a motor command. Sending RX
    /// feedback never updates this observation; no report means nil.
    public func observedFader(_ index: Int) -> UInt8? {
        observedFaders[index]
    }

    public func isTouched(_ index: Int) -> Bool {
        touchedFaders.contains(index) || safetyTouches.contains(index)
    }

    public func isMotorPending(_ index: Int) -> Bool {
        pendingMotor.contains(index)
    }

    public func desiredButton(_ index: Int) -> ButtonLight? {
        desiredButtons[index]
    }

    public func desiredRing(_ index: Int) -> RingDisplay? {
        desiredRings[index]
    }

    public func desiredRingStyle(_ index: Int) -> RingStyle? {
        desiredStyles[index]
    }

    public func isButtonDown(_ index: Int) -> Bool {
        pressedButtons.contains(index)
    }

    public func isEncoderPushed(_ index: Int) -> Bool {
        pushedEncoders.contains(index)
    }

    /// Always send Program Change on (re)connect; physical A/B presses are not host-visible.
    /// Deliberately do NOT recall motor positions on reconnect until operator opts in.
    public mutating func connect() throws -> [MIDIMessage] {
        lastMotorCommands.removeAll()
        observedIsCurrent.removeAll()
        observedFaders.removeAll()
        lastSentButtons.removeAll()
        lastSentRings.removeAll()
        lastSentStyles.removeAll()
        pendingMotor.removeAll()
        pressedButtons.removeAll()
        pushedEncoders.removeAll()
        var result = [map.selectLayer(layer)]
        result += try restoreNonMotorFeedback()
        return result
    }

    @discardableResult
    public mutating func selectLayer(_ layer: CompactLayer) -> MIDIMessage {
        // An explicit assertion, including re-aligning the current layer, invalidates old
        // layer evidence. This is not a physical acknowledgement and never recalls motors.
        pendingMotor.removeAll()
        desiredFader.removeAll()
        invalidateMotorCommandHistory()
        observedLayer = nil
        self.layer = layer
        // Never suppress layer assertions because physical button presses may change it invisibly.
        return map.selectLayer(layer)
    }

    /// Decode input and invalidate stale feedback cache where local hardware behavior may overwrite LEDs.
    /// The domain engine consumes the returned CompactInput and chooses the resulting parameter value.
    public mutating func receive(_ message: MIDIMessage) -> CompactInput? {
        guard let event = map.decode(message) else { return nil }
        observedLayer = event.layer
        switch event.control {
        case let .fader(i):
            observedFaders[i] = event.value
            observedIsCurrent.insert(i)
        case let .faderTouch(i):
            if event.isPressed == true {
                touchedFaders.insert(i)
            } else {
                touchedFaders.remove(i)
            }
        case let .encoder(i): lastSentRings.removeValue(forKey: i)
        case let .button(i):
            if event.isPressed == true {
                pressedButtons.insert(i)
            } else {
                pressedButtons.remove(i)
            }
            if event.isPressed == true, (34 ... 39).contains(i) {
                // The six right-area transport buttons may redraw *the whole group* locally.
                for index in 34 ... 39 {
                    lastSentButtons.removeValue(forKey: index)
                }
            } else if event.isPressed == false {
                lastSentButtons.removeValue(forKey: i)
            }
        case let .encoderPush(i):
            if event.isPressed == true {
                pushedEncoders.insert(i)
            } else {
                pushedEncoders.remove(i)
            }
        }
        return event
    }

    /// Use only after a decoded fader-touch release; compare with the observed physical position.
    public mutating func reconcileReleasedFader(_ index: Int) throws -> [MIDIMessage] {
        guard (1 ... 9).contains(index) else { throw CompactError.invalidIndex("fader", index) }
        guard !isTouched(index), !layerMismatch, pendingMotor.contains(index),
              let desired = desiredFader[index] else { return [] }
        pendingMotor.remove(index)
        if observedIsCurrent.contains(index), observedFaders[index] == desired {
            return []
        }
        if !observedIsCurrent.contains(index), lastMotorCommands[index] == desired {
            return []
        }
        lastMotorCommands[index] = desired
        observedIsCurrent.remove(index)
        return try [map.motorPosition(fader: index, value: desired)]
    }

    /// When touched, only update desired state; never drive the motor against the user's hand.
    public mutating func setFader(_ index: Int, value: UInt8) throws -> [MIDIMessage] {
        guard (1 ... 9).contains(index) else { throw CompactError.invalidIndex("fader", index) }
        desiredFader[index] = value
        guard !layerMismatch else { pendingMotor.remove(index); return [] }
        if isTouched(index) {
            pendingMotor.insert(index)
            return []
        }
        if observedIsCurrent.contains(index) {
            guard observedFaders[index] != value else { return [] }
        } else {
            guard lastMotorCommands[index] != value else { return [] }
        }
        lastMotorCommands[index] = value
        observedIsCurrent.remove(index)
        return try [map.motorPosition(fader: index, value: value)]
    }

    /// Safety ownership is independent of the currently selected transport (e.g. hardware while mocking).
    public mutating func setSafetyTouch(_ index: Int, touched: Bool) {
        guard (1 ... 9).contains(index) else { return }
        if touched {
            safetyTouches.insert(index)
        } else {
            safetyTouches.remove(index)
        }
    }

    public mutating func cancelMotorIntents() {
        pendingMotor.removeAll(); desiredFader.removeAll(); invalidateMotorCommandHistory()
        observedFaders.removeAll(); observedLayer = nil
    }

    public mutating func setInputTouches(_ touches: Set<Int>) {
        touchedFaders = touches
    }

    public mutating func acceptPhysicalFader(_ index: Int) {
        desiredFader.removeValue(forKey: index)
        pendingMotor.remove(index)
        lastMotorCommands.removeValue(forKey: index)
    }

    public mutating func setButton(_ index: Int, light: ButtonLight) throws -> [MIDIMessage] {
        guard (1 ... 39).contains(index) else { throw CompactError.invalidIndex("button", index) }
        desiredButtons[index] = light
        guard lastSentButtons[index] != light else { return [] }
        lastSentButtons[index] = light
        return try [map.buttonLight(button: index, light: light, style: lightProtocol)]
    }

    public mutating func setRing(_ index: Int, display: RingDisplay) throws -> [MIDIMessage] {
        guard (1 ... 16).contains(index) else { throw CompactError.invalidIndex("encoder", index) }
        let midi = try map.encoderRingValue(encoder: index, display: display)
        desiredRings[index] = display
        guard lastSentRings[index] != display else { return [] }
        lastSentRings[index] = display
        return [midi]
    }

    public mutating func setRingStyle(_ index: Int, style: RingStyle) throws -> [MIDIMessage] {
        guard (1 ... 16).contains(index) else { throw CompactError.invalidIndex("encoder", index) }
        desiredStyles[index] = style
        guard lastSentStyles[index] != style else { return [] }
        lastSentStyles[index] = style
        var result = try [map.encoderRingStyle(encoder: index, style: style)]
        // Changing ring style locally redraws the ring: replay the host-owned position.
        lastSentRings.removeValue(forKey: index)
        if let display = desiredRings[index] {
            result += try setRing(index, display: display)
        }
        return result
    }

    public mutating func invalidateNonMotorFeedback() {
        lastSentButtons.removeAll()
        lastSentRings.removeAll()
        lastSentStyles.removeAll()
    }

    public mutating func invalidateMotorCommandHistory() {
        lastMotorCommands.removeAll()
        observedIsCurrent.removeAll()
    }

    public mutating func restoreNonMotorFeedback() throws -> [MIDIMessage] {
        var result: [MIDIMessage] = []
        for index in desiredStyles.keys.sorted() {
            if let style = desiredStyles[index] {
                result += try setRingStyle(index, style: style)
            }
        }
        for index in desiredRings.keys.sorted() {
            if let display = desiredRings[index] {
                result += try setRing(index, display: display)
            }
        }
        for index in desiredButtons.keys.sorted() {
            if let light = desiredButtons[index] {
                result += try setButton(index, light: light)
            }
        }
        return result
    }
}

public extension CompactState {
    /// A profile change never carries a queued motor intent across configuration boundaries.
    /// Physical touch survives so subsequent writes cannot race a hand already on a fader.
    func reconfigured(map: FactoryStandardMap, lightProtocol: ButtonLightProtocol) -> CompactState {
        var next = CompactState(map: map, lightProtocol: lightProtocol)
        next.layer = layer
        next.touchedFaders = touchedFaders
        next.safetyTouches = safetyTouches
        next.observedLayer = observedLayer
        next.observedFaders = observedFaders
        next.pressedButtons = pressedButtons
        next.pushedEncoders = pushedEncoders
        next.desiredButtons = desiredButtons
        next.desiredRings = desiredRings
        next.desiredStyles = desiredStyles
        return next
    }
}
