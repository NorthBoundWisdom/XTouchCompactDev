#if os(macOS)
    import CompactRemoteMIDI

    extension CompactMIDIEndpoint {
        /// Bridge host when this is a development remote-hardware endpoint
        /// (`XTouchRemoteMIDI client`), nil for a locally attached port.
        var remoteBridgeHost: String? {
            RemoteMIDIDefaults.bridgeHost(fromEndpointName: name)
        }
    }

    extension CompactMIDIConnection {
        /// Bridge host if either connected endpoint is remote. Remote evidence is not USB sign-off.
        var remoteBridgeHost: String? {
            connectedInput?.remoteBridgeHost ?? connectedOutput?.remoteBridgeHost
        }
    }
#endif
