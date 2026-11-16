#if os(macOS)
    import Foundation
    import XTouchCompactLocalization

    enum CompactEndpointProvenance: String, Equatable, Sendable {
        case unknown, physicalUSB, localVirtual, remoteVirtual
    }

    /// Transport descriptors cannot grant attended hardware qualification.
    enum CompactEndpointQualification: String, Equatable, Sendable { case unverified }

    struct CompactEndpointStamp: Equatable, Sendable {
        var endpoint: CompactMIDIEndpoint?
        var generation: UInt64
        static let simulation = CompactEndpointStamp(endpoint: .init(id: 0, name: "Process-owned simulation", provenance: .localVirtual), generation: 0)
    }

    /// CoreMIDI endpoint identity; never use transient port indices as persistence keys.
    struct CompactMIDIEndpoint: Equatable, Sendable, Identifiable {
        var id: Int32
        var name: String
        var provenance: CompactEndpointProvenance = .unknown
        let qualification = CompactEndpointQualification.unverified
    }

    struct CompactMIDIConnection: Equatable, Sendable {
        var generation: UInt64 = 0
        var inputs: [CompactMIDIEndpoint] = []
        var outputs: [CompactMIDIEndpoint] = []
        var connectedInput: CompactMIDIEndpoint?
        var connectedOutput: CompactMIDIEndpoint?
        var error: LocalizedMessage?

        var isConnected: Bool {
            connectedInput != nil && connectedOutput != nil
        }
    }

#endif
