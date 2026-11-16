import Foundation

public extension CompactControl {
    /// Stable physical identity. Never includes a MIDI address, parameter assignment or layer.
    var accessibilityID: String {
        switch self {
        case let .fader(index): "surface.fader.\(index)"
        case let .faderTouch(index): "surface.touch.\(index)"
        case let .encoder(index): "surface.encoder.\(index)"
        case let .encoderPush(index): "surface.push.\(index)"
        case let .button(index): "surface.button.\(index)"
        case .expression: "surface.expression"
        case .footswitch: "surface.footswitch"
        }
    }
}
