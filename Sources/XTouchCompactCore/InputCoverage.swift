import Foundation

public enum CompactInputGroup: String, CaseIterable, Sendable {
    case faders, touches, encoders, pushes, buttons

    public var controls: [CompactControl] {
        switch self {
        case .faders: (1 ... CompactGeometry.faderCount).map(CompactControl.fader)
        case .touches: (1 ... CompactGeometry.faderCount).map(CompactControl.faderTouch)
        case .encoders: (1 ... CompactGeometry.encoderCount).map(CompactControl.encoder)
        case .pushes: (1 ... CompactGeometry.encoderCount).map(CompactControl.encoderPush)
        case .buttons: (1 ... CompactGeometry.buttonCount).map(CompactControl.button)
        }
    }

    public var requiresPressRelease: Bool {
        self == .touches || self == .pushes || self == .buttons
    }
}

public struct ControlInputReview: Equatable, Sendable {
    public private(set) var eventCount = 0
    public private(set) var minimum: UInt8?
    public private(set) var maximum: UInt8?
    public private(set) var pressCount = 0
    public private(set) var releaseCount = 0
    public private(set) var pairCount = 0
    public private(set) var duplicatePressCount = 0
    public private(set) var unmatchedReleaseCount = 0
    public private(set) var isDown: Bool?
    public private(set) var addresses: Set<MIDIAddress> = []
    public private(set) var lastReceived: Date?

    public init() {}

    mutating func record(_ input: CompactInput, address: MIDIAddress, at time: Date) {
        eventCount += 1; addresses.insert(address); lastReceived = time
        if let pressed = input.isPressed {
            isDown = pressed
            if pressed {
                pressCount += 1
            } else {
                releaseCount += 1
            }
        } else {
            minimum = min(minimum ?? input.value, input.value)
            maximum = max(maximum ?? input.value, input.value)
        }
    }

    mutating func recordPair() {
        pairCount += 1; isDown = false
    }

    mutating func recordDuplicatePress() {
        duplicatePressCount += 1
    }

    mutating func recordUnmatchedRelease() {
        unmatchedReleaseCount += 1
    }
}

public struct CrossLayerRelease: Equatable, Hashable, Sendable {
    public let control: CompactControl
    public let pressedLayer: CompactLayer
    public let releasedLayer: CompactLayer
    public let interveningLayer: CompactLayer?

    public init(control: CompactControl, pressedLayer: CompactLayer, releasedLayer: CompactLayer, interveningLayer: CompactLayer? = nil) {
        self.control = control; self.pressedLayer = pressedLayer
        self.releasedLayer = releasedLayer; self.interveningLayer = interveningLayer
    }
}
