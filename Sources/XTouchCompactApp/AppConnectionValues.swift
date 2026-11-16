#if os(macOS)
    import Foundation
    import XTouchCompactLocalization

    /// CoreMIDI endpoint identity; never use transient port indices as persistence keys.
    struct CompactMIDIEndpoint: Equatable, Sendable, Identifiable {
        var id: Int32
        var name: String
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
