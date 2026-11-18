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
#endif
