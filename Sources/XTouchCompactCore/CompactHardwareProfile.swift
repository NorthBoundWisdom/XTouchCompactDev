import Foundation
import SurfaceControlContracts

/// Explicit factory Standard configuration; it never rewrites a saved device profile.
public struct CompactHardwareConfiguration: Sendable {
    public let transmitChannel: UInt8
    public let receiveChannel: UInt8
    public let lightProtocol: ButtonLightProtocol
    public init(transmitChannel: UInt8 = 0, receiveChannel: UInt8, lightProtocol: ButtonLightProtocol) throws {
        guard transmitChannel < 16, receiveChannel < 16 else { throw ControlContractError("invalid_argument") }
        self.transmitChannel = transmitChannel
        self.receiveChannel = receiveChannel
        self.lightProtocol = lightProtocol
    }

    public var profile: ControlProfile {
        var rows: [ControlDescriptor] = []
        for layer in CompactLayer.allCases {
            for (kind, count) in [("fader", 9), ("touch", 9), ("encoder", 16), ("push", 16), ("button", 39), ("expression", 1), ("footswitch", 1)] {
                for index in 1 ... count {
                    let absolute = ["fader", "encoder", "expression"].contains(kind)
                    rows.append(.init(id: "\(layer.rawValue).\(kind).\(index)", inputKind: absolute ? .absolute : .button,
                                      encoding: absolute ? .scalar : .boolean,
                                      range: absolute ? .init(minimum: 0, maximum: 127, step: 1) : nil,
                                      feedbackRange: kind == "encoder" ? .init(minimum: 0, maximum: 28, step: 1) : nil,
                                      feedbackKinds: kind == "encoder" ? [.value] : (kind == "button" ? [.indicator] : []), acceptsInput: false))
                }
            }
        }
        // The private capability discloses explicit transport configuration. The shared mapping hash covers controls, not capabilities.
        return .init(id: "xtouch.compact.standard.hardware", version: "1.4", controls: rows,
                     capabilities: ["hardware", "controls.stable_ids", "controls.layered", "controls.input_declared", "input.absolute", "input.button", "feedback.value", "feedback.indicator", "feedback.unsequenced", "input.independent_sequence", "events.writer_id",
                                    "x.xtouch.tx_\(transmitChannel + 1).rx_\(receiveChannel + 1).led_\(lightProtocol.rawValue)"])
    }
}

/// The complete output vocabulary of the hardware service. No raw MIDI, motor, bank or mode message exists.
public enum HardwareDisplayMessage: Equatable, Sendable {
    case buttonLight(button: Int, light: ButtonLight)
    case ringDisplay(encoder: Int, value: UInt8)
    case ringStyle(encoder: Int, style: RingStyle)

    public func word(configuration: CompactHardwareConfiguration) throws -> UInt32 {
        let status: UInt8, number: UInt8, value: UInt8
        switch self {
        case let .buttonLight(button, light):
            guard (1 ... 39).contains(button) else { throw ControlContractError("invalid_value") }
            status = 0x90; number = UInt8(button - 1); value = configuration.lightProtocol.velocity(for: light)
        case let .ringDisplay(encoder, display):
            guard (1 ... 16).contains(encoder), display <= 28 else { throw ControlContractError("invalid_value") }
            status = 0xB0; number = UInt8(25 + encoder); value = display
        case let .ringStyle(encoder, style):
            guard (1 ... 16).contains(encoder) else { throw ControlContractError("invalid_value") }
            status = 0xB0; number = UInt8(9 + encoder); value = style.rawValue
        }
        return 0x2000_0000 | UInt32(status | configuration.receiveChannel) << 16 | UInt32(number) << 8 | UInt32(value)
    }
}
