import Foundation
import SurfaceDeviceContracts

public enum CompactNeutralProjectionError: Error, Equatable, Sendable {
    case missingCapturedFact(String), unsupportedMessage
}

/// Trusted adapter receipt. A remote request parser never constructs this value.
public struct CompactReceiptContext: Sendable {
    public let instanceID: String
    public let endpoint: EndpointProvenance
    public let source: SurfaceDeviceContracts.DeviceSource
    public let at: Double
    public init(instanceID: String, endpoint: EndpointProvenance, source: SurfaceDeviceContracts.DeviceSource, at: Double) throws {
        guard !instanceID.isEmpty, at.isFinite else { throw CompactNeutralProjectionError.missingCapturedFact("receipt") }
        self.instanceID = instanceID; self.endpoint = endpoint; self.source = source; self.at = at
    }
}

/// Read-only device knowledge. No parameter authority, sender or safety-policy switch.
public enum CompactNeutralProjection: Sendable {
    public static func elementID(_ control: CompactControl) -> String {
        switch control {
        case let .fader(i): "fader.position.\(i)"
        case let .faderTouch(i): "fader.touch.\(i)"
        case let .encoder(i): "encoder.rotate.\(i)"
        case let .encoderPush(i): "encoder.press.\(i)"
        case let .button(i): "button.press.\(i)"
        case .expression: "pedal.expression.position"
        case .footswitch: "pedal.footswitch.press"
        }
    }

    public static func logicalTargetID(_ control: CompactControl, layer: CompactLayer) -> String {
        let kind: String, index: Int
        switch control {
        case let .fader(i): kind = "fader"; index = i
        case let .faderTouch(i): kind = "touch"; index = i
        case let .encoder(i): kind = "encoder"; index = i
        case let .encoderPush(i): kind = "push"; index = i
        case let .button(i): kind = "button"; index = i
        case .expression: kind = "expression"; index = 1
        case .footswitch: kind = "footswitch"; index = 1
        }
        return "\(layer.rawValue).\(kind).\(index)"
    }

    public static func context(instanceID: String, routeGeneration: UInt64, bindingGeneration: UInt64,
                               hostLayer: CompactLayer, inputFacet: CompactLayer? = nil,
                               knownHardwareLayer: CompactLayer? = nil, mappingRevision: String? = nil, hardwareEvidenceIsPrior: Bool = false) throws -> DeviceContext
    {
        try .init(id: instanceID + "|host-bank=" + hostLayer.rawValue + "|input-facet=" +
            (inputFacet?.rawValue ?? "unknown") + (hardwareEvidenceIsPrior ? "|prior-device-layer=" : "|device-layer=") + (knownHardwareLayer?.rawValue ?? "unknown"),
            generation: "route:\(routeGeneration):binding:\(bindingGeneration)", mappingRevision: mappingRevision)
    }

    public static func input(_ input: CompactInput, context: DeviceContext, endpoint: EndpointProvenance,
                             source: SurfaceDeviceContracts.DeviceSource, at: Double) throws -> DeviceInputEvent
    {
        let kind: InputKind = switch input.control {
        case .faderTouch: input.isPressed == true ? .contactBegan : .contactEnded
        default: input.isPressed.map { $0 ? .press : .release } ?? .absolute
        }
        return try .init(elementID: elementID(input.control), kind: kind,
                         value: input.isPressed.map(DeviceValue.flag) ?? .number(Double(input.value)),
                         context: context, endpoint: endpoint, source: source, at: at)
    }

    public static func observation(_ input: DeviceInputEvent) throws -> DeviceObservation {
        let facet = switch input.kind {
        case .absolute: "position"
        case .relative: "relative-delta"
        case .press, .release: "pressed"
        case .contactBegan, .contactEnded: "contact"
        }
        return try .init(targetID: input.elementID + ".input." + facet, value: input.value, state: .observed,
                         evidence: .deviceReport, context: input.context, endpoint: input.endpoint, source: input.source, at: input.at)
    }

    public static func feedback(_ message: MIDIMessage, map: FactoryStandardMap, hostLayer: CompactLayer,
                                effectID: String, context: DeviceContext, endpoint: EndpointProvenance,
                                source: SurfaceDeviceContracts.DeviceSource, at: Double) throws -> EffectDescriptor
    {
        let target: String, affected: Set<String>, value: DeviceValue, category: EffectClassification, sideEffects: Set<EffectDirection>
        if case let .programChange(_, number) = message {
            target = "device.layer"; affected = Set((1 ... 9).map { elementID(.fader($0)) })
            value = .number(Double(number)); category = .management; sideEffects = [.mechanism]
        } else {
            let address: MIDIAddress
            switch message {
            case let .controlChange(c, n, _): address = .init(messageType: .controlChange, channel: c, number: n)
            case let .noteOn(c, n, _), let .noteOff(c, n, _): address = .init(messageType: .note, channel: c, number: n)
            default: throw CompactNeutralProjectionError.unsupportedMessage
            }
            let controls = (1 ... 9).map(CompactControl.fader) + (1 ... 16).map(CompactControl.encoder) + (1 ... 39).map(CompactControl.button)
            if let control = controls.first(where: { map.feedbackAddress(for: $0) == address }) {
                target = logicalTargetID(control, layer: hostLayer)
                affected = [elementID(control)]
                if case .fader = control {
                    category = .mechanism
                } else {
                    category = .display
                }
            } else if let encoder = (1 ... 16).first(where: { map.encoderRingStyleAddress(encoder: $0) == address }) {
                target = logicalTargetID(.encoder(encoder), layer: hostLayer) + ".style"
                affected = [elementID(.encoder(encoder))]; category = .display
            } else {
                throw CompactNeutralProjectionError.unsupportedMessage
            }
            switch message {
            case let .controlChange(_, _, byte), let .noteOn(_, _, byte), let .noteOff(_, _, byte): value = .number(Double(byte))
            default: throw CompactNeutralProjectionError.unsupportedMessage
            }
            sideEffects = []
        }
        return try .init(id: effectID, targetID: target, affectedElements: affected, value: value,
                         classification: category, sideEffects: sideEffects, context: context, endpoint: endpoint,
                         source: source, timing: .immediate, at: at)
    }

    public static func capabilities(hardwareService: Bool = false) throws -> DeviceCapabilities {
        let controls = (1 ... 9).map(CompactControl.fader) + (1 ... 9).map(CompactControl.faderTouch)
            + (1 ... 16).map(CompactControl.encoder) + (1 ... 16).map(CompactControl.encoderPush)
            + (1 ... 39).map(CompactControl.button) + [.expression, .footswitch]
        let elements = try controls.map { control -> ElementCapability in
            let input: [InputCapability]
            let displays: [DisplayCapability]
            let effects: [EffectCapability]
            switch control {
            case .fader:
                input = [.init(kind: .absolute, valueKind: .number)]; displays = []
                effects = try hardwareService ? [] : [.init(kind: "motor", classification: .mechanism, sideEffects: []), .init(kind: "layer-assertion", classification: .management, sideEffects: [.mechanism])]
            case .faderTouch:
                input = [.init(kind: .contactBegan, valueKind: .flag), .init(kind: .contactEnded, valueKind: .flag)]; displays = []; effects = []
            case .encoder:
                input = [.init(kind: .absolute, valueKind: .number)]
                displays = try [.init(kind: "ring", valueKind: .number), .init(kind: "style", valueKind: .number)]
                effects = try [.init(kind: "ring", classification: .display, sideEffects: [])]
            case .button:
                input = [.init(kind: .press, valueKind: .flag), .init(kind: .release, valueKind: .flag)]
                displays = try [.init(kind: "light", valueKind: .number)]; effects = try [.init(kind: "light", classification: .display, sideEffects: [])]
            case .encoderPush, .footswitch:
                input = [.init(kind: .press, valueKind: .flag), .init(kind: .release, valueKind: .flag)]; displays = []; effects = []
            case .expression:
                input = [.init(kind: .absolute, valueKind: .number)]; displays = []; effects = []
            }
            return try .init(elementID: elementID(control), inputs: input, displays: displays, effects: effects)
        }
        return try .init(profileID: hardwareService ? "compact.standard.display-service" : "compact.standard.console",
                         modes: [.init(id: "standard-midi", elements: elements)])
    }
}

/// Immutable planning facts, never permissions, parameter values or transmission evidence.
public struct CompactPlannedProvenance: Equatable, Sendable {
    public let id: String
    public let source: SurfaceDeviceContracts.DeviceSource
    public let endpoint: EndpointProvenance
    public let context: DeviceContext
    public let origin: ParameterWriter
    public let at: Double
    public init(id: String, source: SurfaceDeviceContracts.DeviceSource, endpoint: EndpointProvenance,
                context: DeviceContext, origin: ParameterWriter, at: Double) throws
    {
        guard !id.isEmpty, at.isFinite else { throw CompactNeutralProjectionError.missingCapturedFact("planned provenance") }
        self.id = id; self.source = source; self.endpoint = endpoint; self.context = context; self.origin = origin; self.at = at
    }
}
