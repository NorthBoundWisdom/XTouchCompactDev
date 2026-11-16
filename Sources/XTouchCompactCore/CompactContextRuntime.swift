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

/// Package-only test hooks: no implementation, allocation or history is installed by default.
/// A reference is a value existential; only tests provide its old algorithms.
package struct CompactContextComparison: Equatable, Sendable, Codable {
    package let operation: String
    package let input: String
    package let native: String
    package let candidate: String
    package var matches: Bool {
        native == candidate
    }

    package init(operation: String, input: String, native: String, candidate: String) {
        self.operation = operation; self.input = input; self.native = native; self.candidate = candidate
    }
}

package struct CompactResourceSnapshot: Equatable, Sendable {
    package let ids: [Int]
    package let scopes: [Int: CompactResourceScope]
    package init(ids: [Int], scopes: [Int: CompactResourceScope]) {
        self.ids = ids; self.scopes = scopes
    }
}

package enum CompactResourceMutation: Sendable {
    case upsert(id: Int, scope: CompactResourceScope, value: String?)
    case remove(id: Int)
    case removeAll
}

package protocol CompactContextAuditReader: Sendable {
    var recordedComparisons: [CompactContextComparison] { get }
}

package protocol CompactResourceReference: Sendable {
    mutating func apply(_ registry: String, event: CompactResourceMutation, before: CompactResourceSnapshot, after: CompactResourceSnapshot, removed: [Int])
    func read(_ registry: String, id: Int?, actual: String)
    mutating func reset()
    var audit: any CompactContextAuditReader { get }
}

package protocol CompactBindingReference: Sendable {
    mutating func configure(generation: UInt64, changed: Bool)
    mutating func replace(configuration: SurfaceConfiguration)
    func lookup(_ control: CompactControl, layer: CompactLayer, target: String?, action: ParameterAction?)
    var audit: any CompactContextAuditReader { get }
}

package struct CompactContextReferences: Sendable {
    package var resources: any CompactResourceReference
    package var bindings: any CompactBindingReference
    package init(resources: any CompactResourceReference, bindings: any CompactBindingReference) {
        self.resources = resources; self.bindings = bindings
    }
}
