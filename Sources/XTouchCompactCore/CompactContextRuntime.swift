import Foundation
import SurfaceBindingContext
import SurfaceDeviceContracts

/// Stable facts actually owned by this reducer. Missing transport/source is not guessed.
package struct CompactResourceScope: Equatable, Sendable {
    var hostLayer: CompactLayer = .a
    var source: SurfaceDeviceContracts.DeviceSource?
    var endpoint: EndpointProvenance?
    var transmitChannel: UInt8 = 0
    var receiveChannel: UInt8 = 0
    var lightProtocol = ButtonLightProtocol.manual.rawValue
    var bindingGeneration: UInt64 = 0
    var authorizationRouteGeneration: UInt64 = 0
}

/// Binding keys refer to native actions; their values are never copied to the shared index.
enum CompactBindingKey {
    static func kinds(_ control: CompactControl) -> [InputKind] {
        switch control {
        case .fader, .encoder, .expression: [.absolute]
        case .faderTouch: [.contactBegan, .contactEnded]
        case .button, .encoderPush, .footswitch: [.press, .release]
        }
    }

    static func context(_ configuration: SurfaceConfiguration, generation: UInt64) -> BindingContext {
        let entries = configuration.assignments.enumerated().flatMap { offset, assignment in
            kinds(assignment.control).map { kind in
                try! ContextBinding(elementID: assignment.control.neutralElementID, facetID: assignment.layer.rawValue,
                                    inputKind: kind, targetReferenceID: String(offset))
            }
        }
        return BindingContext(context: try! .init(id: "compact.bindings", generation: String(generation), mappingRevision: nil), entries: entries)
    }
}
