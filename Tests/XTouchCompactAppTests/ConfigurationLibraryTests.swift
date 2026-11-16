#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @Test @MainActor func libraryConfirmationPreservesProfileValuesTouchesAndNeverRecallsMotors() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let clock = TestClock()
        let model = ConsoleModel(startsMIDI: false, now: { clock.date }, storageRoot: root, isolated: true)
        model.transmitChannel = 3; model.feedbackChannel = 12; model.observedLEDVariant = true; model.configure()
        model.saveLibraryConfiguration(name: " Studio ")
        let entry = try #require(model.libraryEntries.first)
        #expect(entry.name == "Studio")
        model.saveLibraryConfiguration(name: "Studio")
        #expect(model.libraryEntries.count == 1 && model.panelSnapshot.libraryWarning != nil)
        var changed = model.session.parameters.configuration; changed.parameters[0].name = "Edited"
        model.applyConfiguration(changed)
        model.setParameter("a.Fader.1", value: 83)
        model.touchFader(1, isTouched: true)
        model.clearMonitor()
        model.requestLibraryAction(entry.id, kind: .load)
        #expect(model.session.parameters.configuration == changed)
        model.cancelLibraryAction(); model.confirmLibraryAction()
        #expect(model.session.parameters.configuration == changed)
        model.requestLibraryAction(entry.id, kind: .load); model.confirmLibraryAction()
        #expect(model.session.parameters.configuration == entry.configuration)
        #expect(model.session.parameters.values["a.Fader.1"] == 83)
        #expect(model.session.state.isTouched(1))
        #expect(!model.mcpMotorWritesAllowed)
        #expect(model.transmitChannel == 3 && model.feedbackChannel == 12 && model.observedLEDVariant)
        #expect(!model.events.contains { $0.direction == .output && $0.control == .fader(1) })
        model.touchFader(1, isTouched: false)
        #expect(!model.events.contains { $0.direction == .output && $0.control == .fader(1) })
        model.requestLibraryAction(entry.id, kind: .delete)
        #expect(model.libraryEntries.count == 1)
        model.confirmLibraryAction()
        #expect(model.libraryEntries.isEmpty)
        let restored = ConsoleModel(startsMIDI: false, storageRoot: root, isolated: true)
        #expect(restored.libraryEntries.isEmpty)
    }

    @Test @MainActor func corruptLibraryWarningSurvivesActionsAndOriginalStaysProtected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ConfigurationLibraryStore(directory: root)
        try Data("bad library".utf8).write(to: store.url)
        let model = ConsoleModel(startsMIDI: false, storageRoot: root, isolated: true)
        #expect(model.panelSnapshot.libraryWarning != nil)
        model.dismissNotification("runtime")
        model.saveLibraryConfiguration(name: "New")
        #expect(model.panelSnapshot.libraryWarning != nil && model.libraryEntries.isEmpty)
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "bad library")
    }
#endif
