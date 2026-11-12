import Foundation

/// MIDI channels are zero-based internally: 0 means MIDI channel 1.
public enum MIDIMessage: Equatable, Sendable, CustomStringConvertible {
    case controlChange(channel: UInt8, number: UInt8, value: UInt8)
    case noteOn(channel: UInt8, number: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, number: UInt8, velocity: UInt8)
    case programChange(channel: UInt8, number: UInt8)
    case pitchBend(channel: UInt8, value: UInt16)

    public var description: String {
        switch self {
        case let .controlChange(c, n, v): "CC ch\(c + 1) #\(n)=\(v)"
        case let .noteOn(c, n, v): "Note On ch\(c + 1) #\(n)=\(v)"
        case let .noteOff(c, n, v): "Note Off ch\(c + 1) #\(n)=\(v)"
        case let .programChange(c, n): "Program Change ch\(c + 1) #\(n)"
        case let .pitchBend(c, v): "Pitch Bend ch\(c + 1) #\(v)"
        }
    }

    public var midi1Bytes: [UInt8] {
        switch self {
        case let .controlChange(c, n, v): [0xB0 | c, n, v]
        case let .noteOn(c, n, v): [0x90 | c, n, v]
        case let .noteOff(c, n, v): [0x80 | c, n, v]
        case let .programChange(c, n): [0xC0 | c, n]
        case let .pitchBend(c, v): [0xE0 | c, UInt8(v & 0x7F), UInt8((v >> 7) & 0x7F)]
        }
    }
}

public enum CompactLayer: String, Codable, Sendable, CaseIterable { case a, b }

/// Physical identity is independent from MIDI input identity and MIDI feedback address.
public enum CompactControl: Codable, Hashable, Sendable, CustomStringConvertible {
    case fader(Int) // 1...9, master = 9
    case faderTouch(Int) // 1...9
    case encoder(Int) // 1...16
    case encoderPush(Int) // 1...16
    case button(Int) // 1...39
    /// Optional rear-panel accessories. Not part of the 89 built-in bring-up actions.
    case expression
    case footswitch

    public var description: String {
        switch self {
        case let .fader(i): "Fader \(i)"
        case let .faderTouch(i): "Fader \(i) touch"
        case let .encoder(i): "Encoder \(i)"
        case let .encoderPush(i): "Encoder \(i) push"
        case let .button(i): "Button \(i)"
        case .expression: "Expression pedal"
        case .footswitch: "Footswitch"
        }
    }
}

/// Raw input values are not confused with application parameter values or feedback values.
public struct CompactInput: Equatable, Sendable {
    public var control: CompactControl
    public var layer: CompactLayer
    public var value: UInt8
    public var isPressed: Bool?

    public init(control: CompactControl, layer: CompactLayer, value: UInt8, isPressed: Bool? = nil) {
        self.control = control
        self.layer = layer
        self.value = value
        self.isPressed = isPressed
    }
}

public enum ButtonLight: UInt8, Sendable, CaseIterable { case off, on, blink }
public enum RingStyle: UInt8, Sendable, CaseIterable { case single, pan, fan, spread, trim }
public enum RingDisplay: Equatable, Sendable {
    case off
    case position(Int)
    case blinkingPosition(Int)
    case allOn
    case allBlinking
}

/// The official manual and firmware 1.14 hardware observation differ by 1 for the LED velocities.
/// Select explicitly until the user's hardware revision has been characterized.
public enum ButtonLightProtocol: String, Codable, Sendable {
    case manual // Off = 0; On = 1; Blink = 2
    case observed114 // Off = 0; On = 2; Blink = 3 (JetsonHacks hardware observation)

    public func velocity(for light: ButtonLight) -> UInt8 {
        switch (self, light) {
        case (_, .off): 0
        case (.manual, .on): 1
        case (.manual, .blink): 2
        case (.observed114, .on): 2
        case (.observed114, .blink): 3
        }
    }
}

public enum CompactError: Error, Equatable, Sendable {
    case invalidChannel(UInt8)
    case invalidIndex(String, Int)
    case invalidDisplayPosition(Int)
    case invalidMIDIValue(UInt8)
}

public enum CompactGeometry {
    public static let faderCount = 9
    public static let encoderCount = 16
    public static let buttonCount = 39
    public static let totalInputActions = 9 + 9 + 16 + 16 + 39 // includes 9 touch sensors
}
