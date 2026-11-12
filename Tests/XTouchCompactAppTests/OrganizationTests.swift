#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    /// Swift 6.4.2 asserts when a `#require` result is called directly, so unwrap first.
    @MainActor private func intent<T>(_ value: T?, sourceLocation: SourceLocation = #_sourceLocation) throws -> T {
        try #require(value, sourceLocation: sourceLocation)
    }

    @MainActor private func motorOutputs(_ model: ConsoleModel) -> [MonitorEvent] {
        model.events.filter {
            guard $0.direction == .output, case let .fader(index)? = $0.control else { return false }
            return (1 ... 9).contains(index)
        }
    }

    @Test @MainActor func renameColorAndGroupEditMetadataWithoutMovingAnything() throws {
        let model = ConsoleModel(startsMIDI: false, isolated: true)
        model.clearMonitor()
        try intent(model.panelIntents.renameControl)(.fader(1), "Kick")
        try intent(model.panelIntents.setControlColor)(.fader(1), .red)
        try intent(model.panelIntents.setControlGroup)(.fader(1), "Drums")
        let fader = try #require(model.panelSnapshot.fader(1))
        #expect(fader.label == "Kick" && fader.color == .red && fader.group == "Drums" && fader.parameterID == "a.Fader.1")
        #expect(motorOutputs(model).isEmpty)
        // Blank names and groups are ignored rather than wiping the label.
        try intent(model.panelIntents.renameControl)(.fader(1), "   ")
        try intent(model.panelIntents.setControlGroup)(.fader(1), "")
        #expect(model.panelSnapshot.fader(1)?.label == "Kick" && model.panelSnapshot.fader(1)?.group == "Drums")
        // Highlight is session-only display state.
        try intent(model.panelIntents.highlightGroup)("Drums")
        #expect(model.panelSnapshot.highlightedGroup == "Drums")
    }

    @Test @MainActor func renamingAnUnboundFaderCreatesAParameterAtItsCurrentValue() throws {
        var config = SurfaceConfiguration.neutral
        config.assignments.removeAll { $0.control == .fader(4) && $0.layer == .a }
        let model = ConsoleModel(startsMIDI: false, isolated: true)
        model.applyConfiguration(config)
        model.moveFader(4, value: 77) // Unbound: goes to the bank only.
        #expect(model.panelSnapshot.fader(4)?.parameterID == nil)
        model.clearMonitor()
        try intent(model.panelIntents.renameControl)(.fader(4), "Room")
        let fader = try #require(model.panelSnapshot.fader(4))
        let id = try #require(fader.parameterID)
        #expect(fader.label == "Room" && fader.target == 77)
        #expect(model.session.parameters.values[id] == 77)
        #expect(motorOutputs(model).isEmpty)
        // Buttons are not renamed: they carry actions.
        let before = model.session.parameters.configuration
        try intent(model.panelIntents.renameControl)(.button(1), "Nope")
        #expect(model.session.parameters.configuration == before)
    }

    @Test @MainActor func organizationPersistsAcrossLaunch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ConsoleModel(startsMIDI: false, storageRoot: root, isolated: true)
        try intent(first.panelIntents.renameControl)(.encoder(2), "Reverb")
        try intent(first.panelIntents.setControlColor)(.encoder(2), .purple)
        try intent(first.panelIntents.saveLink)(ParameterLink(id: "l", name: "Bus", leader: "a.Fader.1", members: ["a.Fader.2"]))
        first.setParameter("a.Fader.3", value: 33)
        try intent(first.panelIntents.captureScene)("Verse")
        let restored = ConsoleModel(startsMIDI: false, storageRoot: root, isolated: true)
        #expect(restored.panelSnapshot.encoder(2)?.label == "Reverb")
        #expect(restored.panelSnapshot.encoder(2)?.color == .purple)
        #expect(restored.panelSnapshot.fader(1)?.linkRole == .leader("Bus"))
        #expect(restored.panelSnapshot.fader(2)?.linkRole == .member("Bus"))
        #expect(restored.panelSnapshot.configuration.scenes?.first?.values["a.Fader.3"] == 33)
    }

    @Test @MainActor func sceneRecallChangesTargetsButNotMotorsUntilExplicitRecall() throws {
        let model = ConsoleModel(startsMIDI: false, isolated: true)
        model.setParameter("a.Fader.1", value: 100)
        try intent(model.panelIntents.captureScene)("Loud")
        model.setParameter("a.Fader.1", value: 10)
        #expect(model.mock.faders[0] == 10)
        let scene = try #require(model.panelSnapshot.configuration.scenes?.first)
        model.clearMonitor()
        try intent(model.panelIntents.recallScene)(scene.id)
        #expect(model.panelSnapshot.fader(1)?.target == 100)
        #expect(model.mock.faders[0] == 10) // The cap has not moved.
        #expect(motorOutputs(model).isEmpty)
        model.recallMotors()
        #expect(model.mock.faders[0] == 100)
        // Saving under an existing name updates that scene instead of duplicating it.
        try intent(model.panelIntents.captureScene)("Loud")
        #expect(model.panelSnapshot.configuration.scenes?.count == 1)
        try intent(model.panelIntents.deleteScene)(scene.id)
        #expect(model.panelSnapshot.configuration.scenes?.isEmpty == true)
    }

    @Test @MainActor func linkedFadersAndUndoDriveTheMockMotorsThroughTheSameGates() throws {
        let model = ConsoleModel(startsMIDI: false, isolated: true)
        try intent(model.panelIntents.saveLink)(ParameterLink(id: "l", name: "Bus", leader: "a.Fader.1", members: ["a.Fader.2"]))
        model.setParameter("a.Fader.1", value: 40)
        #expect(model.mock.faders[1] == 40)
        model.touchFader(2, isTouched: true)
        model.setParameter("a.Fader.1", value: 60)
        #expect(model.mock.faders[1] == 40) // Held by hand: deferred.
        #expect(model.panelSnapshot.fader(2)?.isMotorPending == true)
        model.touchFader(2, isTouched: false)
        #expect(model.mock.faders[1] == 60) // Released: aligned once.
        #expect(model.panelSnapshot.canUndo)
        try intent(model.panelIntents.undo)()
        #expect(model.session.parameters.values["a.Fader.1"] == 40 && model.mock.faders[1] == 40)
        try intent(model.panelIntents.redo)()
        #expect(model.mock.faders[0] == 60 && model.mock.faders[1] == 60)
        // An invalid link is rejected with a visible error and leaves the configuration intact.
        let before = model.session.parameters.configuration
        try intent(model.panelIntents.saveLink)(ParameterLink(id: "bad", name: "Loop", leader: "a.Fader.2", members: ["a.Fader.1"]))
        #expect(model.session.parameters.configuration == before)
        #expect(model.error != nil)
        try intent(model.panelIntents.deleteLink)("l")
        #expect(model.panelSnapshot.fader(1)?.linkRole == nil)
    }

    @Test @MainActor func scenesRenameAndLinksEditInPlaceWithoutChangingValues() throws {
        let model = ConsoleModel(startsMIDI: false, isolated: true)
        model.setParameter("a.Fader.1", value: 55)
        try intent(model.panelIntents.captureScene)("Verse")
        try intent(model.panelIntents.captureScene)("Chorus")
        let verse = try #require(model.panelSnapshot.configuration.scenes?.first { $0.name == "Verse" })
        model.clearMonitor()
        try intent(model.panelIntents.renameScene)(verse.id, "  Intro ")
        var scenes = try #require(model.panelSnapshot.configuration.scenes)
        #expect(scenes.map(\.name) == ["Intro", "Chorus"])
        #expect(scenes[0].id == verse.id && scenes[0].values == verse.values)
        // Blank and duplicate names are ignored.
        try intent(model.panelIntents.renameScene)(verse.id, " ")
        try intent(model.panelIntents.renameScene)(verse.id, "Chorus")
        scenes = try #require(model.panelSnapshot.configuration.scenes)
        #expect(scenes.map(\.name) == ["Intro", "Chorus"])
        #expect(motorOutputs(model).isEmpty)

        // Saving a link under its existing ID replaces it in place.
        try intent(model.panelIntents.saveLink)(ParameterLink(id: "l", name: "Bus", leader: "a.Fader.1", members: ["a.Fader.2"]))
        try intent(model.panelIntents.saveLink)(ParameterLink(id: "l", name: "Drums", leader: "a.Fader.1", members: ["a.Fader.3", "a.Fader.4"]))
        let links = try #require(model.panelSnapshot.configuration.links)
        #expect(links.count == 1 && links[0].name == "Drums" && links[0].members == ["a.Fader.3", "a.Fader.4"])
        #expect(model.panelSnapshot.fader(2)?.linkRole == nil)
        #expect(model.panelSnapshot.fader(3)?.linkRole == .member("Drums"))
        #expect(model.session.parameters.values["a.Fader.1"] == 55)
    }
#endif
