import Foundation
import SurfaceControlContracts
import SurfacePluginContracts

/// One value authority for hardware observations and independent display intent.
/// It never owns a motor model or creates device output during input or lifecycle operations.
public struct CompactHardwareSurface: Sendable {
    public private(set) var controls: SurfaceControlSession
    public private(set) var observedLayer: CompactLayer?
    public private(set) var undecodedCount = 0
    public let configuration: CompactHardwareConfiguration
    public let hardwareWriterID: String
    public let remoteWriterID: String

    public init(instanceID: String, epoch: String, configuration: CompactHardwareConfiguration,
                hardwareWriterID: String, remoteWriterID: String, eventCapacity: Int = 1024, writeLimits: ControlWriteLimits? = nil) throws
    {
        self.configuration = configuration
        self.hardwareWriterID = hardwareWriterID
        self.remoteWriterID = remoteWriterID
        var profile = configuration.profile
        if writeLimits != nil {
            profile = .init(id: profile.id, version: profile.version, controls: profile.controls, capabilities: profile.capabilities + ["writes.independent_limits"])
        }
        controls = try .init(instanceID: instanceID, epoch: epoch, profile: profile, eventCapacity: eventCapacity, writeLimits: writeLimits)
        try controls.validateWriterID(hardwareWriterID)
        try controls.validateWriterID(remoteWriterID)
        guard hardwareWriterID != remoteWriterID else { throw ControlContractError("invalid_argument") }
    }

    public mutating func transition(epoch: String, connected: Bool, at time: Double) throws {
        try controls.transitionHardware(epoch: epoch, linkState: connected ? .connected : .disconnected, at: time)
        observedLayer = nil
    }

    @discardableResult public mutating func receive(_ message: MIDIMessage, disposition: ControlDisposition = .accepted, reason: String? = nil, at time: Double) throws -> ControlEvent? {
        let map = try FactoryStandardMap(transmitChannel: configuration.transmitChannel, globalReceiveChannel: configuration.receiveChannel)
        guard let decoded = map.decode(message) else { undecodedCount += 1; return nil }
        let kind: String, index: Int
        switch decoded.control {
        case let .fader(value): kind = "fader"; index = value
        case let .faderTouch(value): kind = "touch"; index = value
        case let .encoder(value): kind = "encoder"; index = value
        case let .encoderPush(value): kind = "push"; index = value
        case let .button(value): kind = "button"; index = value
        case .expression: kind = "expression"; index = 1
        case .footswitch: kind = "footswitch"; index = 1
        }
        let id = "\(decoded.layer.rawValue).\(kind).\(index)"
        let input = ControlHardwareInput(expected: controls.expected, controlID: id, encoding: decoded.isPressed == nil ? "scalar" : "boolean",
                                         value: decoded.isPressed.map(JSONValue.bool) ?? .number(Int(decoded.value)))
        try controls.validateHardwareInput(input, at: time, writerID: hardwareWriterID)
        var next = self
        next.observedLayer = decoded.layer
        let event = try next.controls.recordHardwareInput(input, disposition: disposition, reason: reason, at: time, writerID: hardwareWriterID)
        self = next
        return event
    }

    /// Validate before any transport side effects. The caller then sends this typed plan,
    /// and commits `recordFeedback` only after every message was accepted by the transport.
    public func displayPlan(_ update: ControlFeedback, allowed: Bool, at time: Double) throws -> [HardwareDisplayMessage] {
        try controls.validateFeedback(update, at: time, writerID: remoteWriterID)
        guard allowed else { throw ControlContractError("permission_denied") }
        guard try controls.snapshot(at: time).link?.state == .connected else { throw ControlContractError("invalid_transition") }
        let parts = update.control_id.split(separator: ".")
        guard parts.count == 3, let layer = CompactLayer(rawValue: String(parts[0])), let index = Int(parts[2]) else { throw ControlContractError("unsupported_control") }
        // RX addresses are shared between banks. A request cannot assert or select the bank.
        guard let observedLayer, observedLayer == layer else { throw ControlContractError("invalid_transition") }
        switch parts[1] {
        case "button":
            let light: ButtonLight
            switch update.value.stringValue {
            case "off": light = .off
            case "on": light = .on
            case "blink": light = .blink
            default: throw ControlContractError("invalid_value")
            }
            return [.buttonLight(button: index, light: light)]
        case "encoder":
            guard let value = update.value.exactIntValue, (0 ... 28).contains(value) else { throw ControlContractError("invalid_value") }
            return [.ringStyle(encoder: index, style: .single), .ringDisplay(encoder: index, value: UInt8(value))]
        default: throw ControlContractError("unsupported_feedback")
        }
    }

    @discardableResult public mutating func recordFeedback(_ update: ControlFeedback, at time: Double) throws -> ControlEvent {
        try controls.recordFeedback(update, origin: .remote, at: time, writerID: remoteWriterID)
    }
}
