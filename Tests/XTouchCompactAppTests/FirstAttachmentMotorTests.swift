#if os(macOS)
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @Test(arguments: ["agentWithGrant", "agentWithoutGrant", "interface"])
    @MainActor func firstAttachmentAfterDisconnectedSendSelectionRequiresAction(source: String) throws {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        model.setConsoleMode(.hardwareSend)
        model.mcpWritesAllowed = true
        model.mcpMotorWritesAllowed = source == "agentWithGrant"
        midi.connect()
        midi.sent.removeAll()
        if source == "interface" {
            model.setParameter("a.Fader.1", value: 68)
        } else {
            try model.applyAgentParameter("a.Fader.1", value: 68)
        }
        #expect(midi.sent.filter {
            if case .controlChange(_, 1 ... 9, _) = $0 {
                true
            } else {
                false
            }
        }.isEmpty)
        #expect(model.listenOnly)
        #expect(!model.session.state.isMotorPending(1))
        // A fresh operator choice on the connected route still permits ordinary use.
        model.setConsoleMode(.hardwareSend)
        model.setParameter("a.Fader.1", value: 69)
        #expect(midi.sent.contains(.controlChange(channel: 0, number: 1, value: 69)))
    }
#endif
