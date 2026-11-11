#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore
    import XTouchCompactLocalization

    @Test @MainActor func importBCRFileAndLocalizedStorageRuntimeDismissal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ConsoleModel(startsMIDI: false, storageRoot: root)
        let bcr = root.appendingPathComponent("BCR.json")
        try Data(#"{"surfaceConfiguration":{"encoders":[]}}"#.utf8).write(to: bcr)
        let before = model.session.parameters.configuration
        model.importConfiguration(bcr)
        #expect(model.error as? ParameterError == .wrongDeviceOrVersion)
        #expect(model.errorText(using: Localizer(language: .traditionalChinese)).contains("僅支援"))
        #expect(model.session.parameters.configuration == before)
        let workspace = root.appendingPathComponent("workspace.json")
        try Data("invalid".utf8).write(to: workspace)
        model.retryWorkspaceSave()
        let notice = try #require(model.notifications.first { $0.id == "storage" }?.message)
        #expect(Localizer(language: .traditionalChinese).text(notice).contains("已保留"))
        model.dismissNotification("runtime")
        #expect(model.error == nil)
        #expect(model.notifications.contains { $0.id == "storage" })
    }

    @Test @MainActor func errorNamesRemainLocalizedAfterLanguageChanges() {
        let model = ConsoleModel(startsMIDI: false)
        model.serviceError(CompactMIDIError.operation("Send MIDI", -7))
        let traditional = Localizer(language: .traditionalChinese)
        let simplified = Localizer(language: .simplifiedChinese)
        #expect(model.errorText(using: traditional).contains("傳送 MIDI"))
        #expect(model.errorText(using: simplified).contains("发送 MIDI"))
        #expect(model.errorText(using: Localizer(language: .english)).contains("Send MIDI"))
        model.serviceError(CompactError.invalidIndex("fader", 10))
        #expect(model.errorText(using: traditional).contains("推桿"))
        #expect(model.errorText(using: simplified).contains("推子"))
        #expect(!model.errorText(using: traditional).contains("fader"))
    }
#endif
#if os(macOS)
    @Test @MainActor func presetsAndImportsUseDeclaredDefaultsWhileEditsPreserveValues() throws {
        let model = ConsoleModel(startsMIDI: false)
        model.setParameter("a.Fader.1", value: 83)
        var edited = model.session.parameters.configuration
        edited.parameters[0].name = "Edited"
        model.applyConfiguration(edited)
        #expect(model.session.parameters.values["a.Fader.1"] == 83)
        model.clearMonitor()
        model.loadPreset(.audioExample)
        #expect(model.pendingPreset == .audioExample)
        #expect(model.session.parameters.values["a.Fader.1"] == 83)
        model.cancelLoadPreset()
        #expect(model.pendingPreset == nil)
        #expect(model.session.parameters.configuration == edited)
        model.loadPreset(.audioExample)
        model.confirmLoadPreset()
        #expect(model.session.parameters.values["a.Fader.1"] == -60)
        #expect(model.mock.faders[0] == 83) // Replacing the configuration does not recall motors.
        #expect(!model.events.contains {
            if case let .controlChange(_, n, _) = $0.message {
                return $0.direction == .output && (1 ... 9).contains(n)
            }; return false
        })
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("audio.json")
        try JSONEncoder().encode(SurfaceConfiguration.audioExample).write(to: file)
        model.setParameter("a.Fader.1", value: -10)
        model.clearMonitor()
        model.importConfiguration(file)
        #expect(model.pendingPreset == .audioExample)
        #expect(model.session.parameters.values["a.Fader.1"] == -10)
        model.confirmLoadPreset()
        #expect(model.session.parameters.values["a.Fader.1"] == -60)
        #expect(!model.events.contains {
            if case let .controlChange(_, n, _) = $0.message {
                return $0.direction == .output && (1 ... 9).contains(n)
            }; return false
        })
        // Default-valued workspaces need no redundant confirmation.
        model.loadPreset(.neutral)
        #expect(model.pendingPreset == nil)
        #expect(model.session.parameters.values["a.Fader.1"] == 0)
    }
#endif

#if os(macOS)
    @Test @MainActor func presetConfirmationConsumesOnlyModelOwnedPendingRequest() {
        let model = ConsoleModel(startsMIDI: false)
        model.setParameter("a.Fader.1", value: 83)
        let confirm = model.panelIntents.confirmLoadPreset
        confirm?()
        #expect(model.session.parameters.values["a.Fader.1"] == 83)
        model.loadPreset(.audioExample)
        model.cancelLoadPreset()
        confirm?()
        #expect(model.session.parameters.configuration == .neutral)
        model.loadPreset(.audioExample)
        model.applyConfiguration(.neutral)
        confirm?()
        #expect(model.session.parameters.values["a.Fader.1"] == 83)
        model.loadPreset(.audioExample)
        confirm?()
        #expect(model.session.parameters.configuration == .audioExample)
        model.setParameter("a.Fader.1", value: -10)
        confirm?() // Repeated stale action must not reset a later edit.
        #expect(model.session.parameters.values["a.Fader.1"] == -10)
    }
#endif
