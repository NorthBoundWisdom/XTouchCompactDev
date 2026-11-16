#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @Test @MainActor func macroDefinitionsPersistInLibraryAndLocalRunCannotBypassPhysicalOutputOrTouchGates() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        let macro = SurfaceMacro(id: "cue", name: "Cue", actions: [.set("a.Fader.1", 90), .step("a.Fader.1", 10)])
        model.saveMacro(macro)
        model.saveLibraryConfiguration(name: "Macros")
        #expect(model.libraryEntries.first?.configuration.macros == [macro])
        midi.connect(); model.setConsoleMode(.hardwareListen)
        model.clearMonitor(); midi.sent.removeAll()
        model.runMacro("cue")
        #expect(midi.sent.isEmpty) // Local run cannot enable physical writeback.
        #expect(!model.mcpMotorWritesAllowed && !model.mcpWritesAllowed)
        model.setConsoleMode(.hardwareSend)
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127)])
        model.clearMonitor(); midi.sent.removeAll()
        model.runMacro("cue")
        #expect(!midi.sent.contains {
            if case .controlChange(_, 1, _) = $0 {
                return true
            }; return false
        })
        #expect(model.panelSnapshot.lastMacroExecution?.steps.count == 2)
        #expect(model.session.state.isTouched(1))
        model.deleteMacro("cue")
        #expect(model.session.parameters.configuration.macros?.isEmpty == true)
        #expect(model.libraryEntries.first?.configuration.macros == [macro])
    }
#endif
