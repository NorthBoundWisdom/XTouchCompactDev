#if os(macOS)
    import SurfaceConnectionState
    import XTouchCompactCore

    extension CompactMIDIConnection {
        /// Cosmetic descriptor updates are diagnostic facts, not part of this owner's route key.
        var neutralRoute: SurfaceConnectionState.ConnectionSnapshot<EmptyConnectionIdentity> {
            try! .init(inputID: connectedInput.map { String($0.id) }, outputID: connectedOutput.map { String($0.id) },
                       transportGeneration: generation, isConnected: isConnected, extra: .init())
        }
    }

    protocol CompactConnectionReference: Sendable {
        func willPublish(_ next: CompactMIDIConnection, current: CompactMIDIConnection, changed: Bool, generation: UInt64)
        mutating func didPublish(_ next: CompactMIDIConnection, actual: CompactMIDIConnection, semantic: ConnectionSnapshot<EmptyConnectionIdentity>, generation: UInt64)
        func admission(captured: CompactMIDIConnection, current: CompactMIDIConnection, actual: Bool)
        var published: CompactMIDIConnection { get }
        var audit: any CompactContextAuditReader { get }
    }
#endif
