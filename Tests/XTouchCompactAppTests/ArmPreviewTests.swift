#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @Test @MainActor func optionalArmPanelPersistsSeparatelyAndIsAlwaysReadOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ConsoleModel(startsMIDI: false, storageRoot: root, isolated: true)
        #expect(!model.panelSnapshot.armPreviewVisible && model.panelSnapshot.armPreview == nil)
        model.clearMonitor()
        let show = try #require(model.panelIntents.setArmPreviewVisible)
        show(true)
        #expect(model.panelSnapshot.armPreviewVisible && model.events.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("workspace.json").path))
        let restored = ConsoleModel(startsMIDI: false, storageRoot: root, isolated: true)
        #expect(restored.panelSnapshot.armPreviewVisible)
        model.loadReferenceArmExample()
        let before = model.session.parameters.values
        model.clearMonitor()
        let preview = try #require(model.panelSnapshot.armPreview)
        #expect(preview.joints == [0, 30, -60, -20])
        show(false); show(true)
        #expect(model.session.parameters.values == before && model.events.isEmpty)
        #expect(!model.mcpWritesAllowed && !model.mcpMotorWritesAllowed)
    }
#endif
