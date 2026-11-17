#if os(macOS)
    import Combine
    import Darwin
    import Foundation
    import SurfaceControlContracts
    import SurfacePluginContracts
    import Testing
    @testable import XTouchCompactApp
    @testable import XTouchCompactCore
    import XTouchCompactLocalization

    @MainActor private func guiModel() throws -> ConsoleModel {
        let model = ConsoleModel(startsMIDI: true, virtualSurfaceOnly: true)
        try model.attachGUIVirtualSurface(inputCapacity: 64)
        return model
    }

    @MainActor private func guiFeedback(_ model: ConsoleModel, _ id: String, _ kind: String, _ value: JSONValue) throws -> [String: Any] {
        let expected = try JSONSerialization.jsonObject(with: JSONEncoder().encode(model.guiVirtualSurface!.controls.expected))
        return try model.guiVirtualSurface!.route(["method": "tools/call", "params": ["name": "surface_control_feedback", "arguments": ["expected": expected, "control_id": id, "kind": kind, "value": JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: [.fragmentsAllowed])]]])
    }

    @Test @MainActor func guiVirtualFeedbackRendersSameCanonicalMockWithoutChangingParametersOrInput() throws {
        let model = try guiModel(), port = try #require(model.guiVirtualSurface)
        let values = model.session.parameters.values, undo = model.session.canUndo
        let before = try port.controls.snapshot(at: ProcessInfo.processInfo.systemUptime)
        #expect(try guiFeedback(model, "a.fader.1", "value", .number(64))["isError"] as? Bool == false)
        #expect(try guiFeedback(model, "a.encoder.1", "value", .number(93))["isError"] as? Bool == false)
        #expect(try guiFeedback(model, "a.button.1", "indicator", .string("on"))["isError"] as? Bool == false)
        #expect(model.mock.faders[0] == 64)
        #expect(model.panelSnapshot.faders[0].capPosition == 64)
        #expect(try model.panelSnapshot.faders[0].target == UInt8(#require(values["a.Fader.1"])))
        #expect(model.session.parameters.values == values && model.session.canUndo == undo)
        let after = try port.controls.snapshot(at: ProcessInfo.processInfo.systemUptime)
        #expect(after.inputs == before.inputs && after.latest_input_sequence == before.latest_input_sequence)
        #expect(after.discovery.source == .simulation && after.discovery.profile.id == "xtouch.compact.gui.virtual")
        #expect(!after.discovery.profile.capabilities.contains("input.hold"))
        #expect(model.panelSnapshot.mockPedals == nil)
    }

    @Test @MainActor func guiVirtualLocalGesturesUseCanonicalAuthorityAndIndependentInputJournal() throws {
        let model = try guiModel(), port = try #require(model.guiVirtualSurface)
        model.moveFader(1, value: 23)
        model.touchFader(1, isTouched: true)
        let snapshot = try port.controls.snapshot(at: ProcessInfo.processInfo.systemUptime)
        #expect(model.session.parameters.values["a.Fader.1"] == 23)
        #expect(snapshot.inputs["a.fader.1"] == .number(23) && snapshot.inputs["a.touch.1"] == .bool(true))
        #expect(snapshot.latest_input_sequence == "2")
        #expect(model.session.state.isTouched(1))
        #expect(snapshot.inputs["a.expression.1"] == nil && snapshot.inputs["a.footswitch.1"] == nil)
        let page = try port.controls.inputEvents(expected: port.controls.expected, afterInputSequence: "0", limit: 10, at: ProcessInfo.processInfo.systemUptime)
        #expect(page.events.count == 2)
        #expect(page.events.allSatisfy { $0.origin == .interface && $0.source == .simulation })
    }

    @Test @MainActor func guiVirtualEscapeRevokesIdentityAndClearsSoftwareOverlaysBeforeDenial() throws {
        for attempt in 0 ..< 10 {
            let model = try guiModel(), port = try #require(model.guiVirtualSurface)
            _ = try guiFeedback(model, "a.fader.1", "value", .number(64))
            let previous = port.controls.expected
            switch attempt {
            case 0: model.useHardware(true)
            case 1: model.setConsoleMode(.hardwareSend)
            case 2: model.beginHardwareObservation()
            case 3: model.selectPorts()
            case 4: model.configure()
            case 5: model.loadPreset(.neutral)
            case 6: model.setMCPEnabled(true)
            case 7: model.copyMCPToken()
            case 8: model.setOSCEnabled(true)
            default: model.installOptionalPlugins([.output])
            }
            #expect(!port.active && !model.hardwareMode && !model.mcpEnabled)
            #expect(previous.epoch != port.controls.expected.epoch)
            #expect(throws: (any Error).self) { try port.controls.validateExpected(previous) }
            #expect(model.error != nil && model.mock.faders[0] != 64)
            #expect(try port.controls.snapshot(at: ProcessInfo.processInfo.systemUptime).feedback.isEmpty)
            let revoked = port.controls.expected
            port.revoke()
            #expect(port.controls.expected == revoked) // Reentrant/duplicate teardown is terminal and idempotent.
        }
    }

    @Test @MainActor func guiVirtualDisplayScopeCannotReachLegacyOrInputOrInactiveLayer() throws {
        let model = try guiModel(), port = try #require(model.guiVirtualSurface)
        let listed = try #require(try port.route(["method": "tools/list"])["tools"] as? [[String: Any]])
        let names = Set(listed.compactMap { $0["name"] as? String })
        #expect(names == ["surface_control_discover", "surface_control_snapshot", "surface_control_events", "surface_control_feedback", SurfaceControlInputEventsTools.name])
        for name in ["set_parameter", "surface_control_input", "surface_control_renew", "surface_control_reset", "agent_primary"] {
            #expect(try port.route(["method": "tools/call", "params": ["name": name, "arguments": [:]]])["isError"] as? Bool == true)
        }
        let values = model.session.parameters.values
        #expect(try guiFeedback(model, "b.fader.1", "value", .number(55))["isError"] as? Bool == false)
        #expect(model.mock.faders[0] != 55 && model.session.parameters.values == values)
    }

    @Test func guiVirtualBootstrapIsExplicitBoundedAndRejectsConflictsBeforeFactories() throws {
        #expect(try GUIVirtualOptions.parse(["app"]) == nil)
        for args in [["app", "--gui-virtual-surface=true"], ["app", "--gui-virtual-surface"], ["app", "--gui-surface-ready-fd", "4"], ["app", "--gui-virtual-surface", "--hardware-control"]] {
            #expect(throws: (any Error).self) { try GUIVirtualOptions.parse(args) }
        }
        var fds: [Int32] = [0, 0]
        #expect(pipe(&fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let frame = Data("{\"schema\":1}\n".utf8)
        _ = frame.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) }
        // A valid-looking first frame cannot hide a delayed second frame/no EOF.
        #expect(throws: (any Error).self) { try GUIVirtualFD.readFrame(fds[0], timeout: 0.02) }
        close(fds[1]); fds[1] = -1
        var closed: [Int32] = [0, 0]; #expect(pipe(&closed) == 0)
        defer { close(closed[0]) }
        _ = frame.withUnsafeBytes { write(closed[1], $0.baseAddress, $0.count) }
        close(closed[1])
        #expect(try GUIVirtualFD.readFrame(closed[0], timeout: 0.2) == frame.dropLast())
    }

    @Test @MainActor func guiVirtualJournalFailureRevokesBeforeBusinessCommitAndOldIdentityCannotSurviveBadClock() throws {
        var time = 10.0
        let model = ConsoleModel(virtualSurfaceOnly: true, eventMonotonicClock: { time })
        try model.attachGUIVirtualSurface(inputCapacity: 64)
        let port = try #require(model.guiVirtualSurface)
        model.moveFader(1, value: 23)
        let previous = port.controls.expected
        time = 9
        model.moveFader(1, value: 47)
        #expect(model.session.parameters.values["a.Fader.1"] == 23)
        #expect(!port.active && model.error != nil)
        #expect(previous.epoch != port.controls.expected.epoch)
    }

    @Test func guiVirtualReadyBackpressureAndDelayedSecondFrameFailWithinBound() async throws {
        var fds: [Int32] = [0, 0]; #expect(pipe(&fds) == 0)
        defer { close(fds[0]) }
        // Fill the platform's actual pipe capacity first; do not assume a buffer size.
        _ = fcntl(fds[1], F_SETFL, fcntl(fds[1], F_GETFL) | O_NONBLOCK)
        var fill = [UInt8](repeating: 0, count: 4096)
        while Darwin.write(fds[1], &fill, fill.count) > 0 {}
        #expect(errno == EAGAIN)
        // No reader drains this full pipe; the bounded writer must return an error.
        #expect(throws: (any Error).self) { try GUIVirtualFD.writeFrame(Data(repeating: 1, count: 32768), to: fds[1], timeout: 0.02) }
        var bootstrap: [Int32] = [0, 0]; #expect(pipe(&bootstrap) == 0)
        defer { close(bootstrap[0]) }
        let writer = bootstrap[1]
        let delayed = Task.detached {
            let first = Data("{}\n".utf8)
            _ = first.withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
            try? await Task.sleep(for: .milliseconds(10))
            _ = first.withUnsafeBytes { write(writer, $0.baseAddress, $0.count) }
            close(writer)
        }
        #expect(throws: (any Error).self) { try GUIVirtualFD.readFrame(bootstrap[0], timeout: 0.2) }
        await delayed.value
    }

    @Test @MainActor func guiVirtualPublishesCommittedInputJournalBeforeReentrantUIObservation() throws {
        let midi = FakeMIDIService()
        let model = ConsoleModel(virtualSurfaceOnly: true, midi: midi)
        try model.attachGUIVirtualSurface(inputCapacity: 64)
        let port = try #require(model.guiVirtualSurface)
        var sawCommitted = false
        let observer = model.objectWillChange.sink {
            if model.session.parameters.values["a.Fader.1"] == 23 {
                sawCommitted = true
                let snapshot = try? port.controls.snapshot(at: ProcessInfo.processInfo.systemUptime)
                #expect(snapshot?.inputs["a.fader.1"] == .number(23))
                #expect(snapshot?.latest_input_sequence == "1")
            }
        }
        model.moveFader(1, value: 23)
        withExtendedLifetime(observer) {}
        #expect(sawCommitted)
        #expect(midi.starts == 0 && midi.sent.isEmpty && midi.sendAttempts == 0)
    }

    @Test @MainActor func guiVirtualLowestConfigurationAndConfirmationRoutesRevokeWithoutBindingMutation() throws {
        for attempt in 0 ..< 12 {
            let model = try guiModel(), port = try #require(model.guiVirtualSurface)
            let original = model.session.parameters.configuration, binding = model.session.writeAuthorization.bindingGeneration, identity = port.controls.expected
            switch attempt {
            case 0: model.applyConfiguration(.neutral)
            case 1: model.confirmLoadPreset()
            case 2: model.saveMacro(.init(id: "escape", name: "Escape", actions: [.set("a.Fader.1", 63)]))
            case 3: model.deleteMacro("escape")
            case 4: model.requestLibraryAction(UUID(), kind: .load)
            case 5: model.confirmLibraryAction()
            case 6: model.saveLibraryConfiguration(name: "Escape")
            case 7: model.resetParameterValues()
            case 8: model.renameControl(.fader(1), name: "Escape")
            case 9: model.setControlGroup(.fader(1), group: "Escape")
            case 10: model.captureScene(name: "Escape")
            default: model.deleteScene("escape")
            }
            #expect(!port.active && port.controls.expected.epoch != identity.epoch)
            #expect(model.session.parameters.configuration == original)
            #expect(model.session.writeAuthorization.bindingGeneration == binding)
            #expect(model.error != nil)
        }
    }

    @Test @MainActor func guiVirtualFeedbackHonorsCanonicalDisplayAndMechanismPolicyWithoutJournalOrBudgetCommit() throws {
        let model = try guiModel(), port = try #require(model.guiVirtualSurface)
        var policy = model.session.writeAuthorization
        policy.allowsDisplay = false
        try model.configureWriteAuthorization(policy)
        let before = try port.controls.snapshot(at: ProcessInfo.processInfo.systemUptime)
        let ring = model.session.state.desiredRing(1)
        for _ in 0 ..< 61 {
            #expect(try guiFeedback(model, "a.encoder.1", "value", .number(93))["isError"] as? Bool == true)
        }
        #expect(try port.controls.snapshot(at: ProcessInfo.processInfo.systemUptime).latest_sequence == before.latest_sequence)
        #expect(model.session.state.desiredRing(1) == ring)
        policy.allowsDisplay = true; policy.allowsMechanisms = false
        try model.configureWriteAuthorization(policy)
        #expect(try guiFeedback(model, "a.fader.1", "value", .number(64))["isError"] as? Bool == true)
        #expect(try guiFeedback(model, "a.encoder.1", "value", .number(93))["isError"] as? Bool == false)
        #expect(model.mock.faders[0] != 64)
        #expect(try port.controls.snapshot(at: ProcessInfo.processInfo.systemUptime).latest_sequence == "1")
    }

    @Test @MainActor func guiVirtualFeedbackReentrantRevocationCannotResurrectEndpointOrOverwriteNewJournal() throws {
        let model = try guiModel(), port = try #require(model.guiVirtualSurface)
        var invoked = false
        let observer = model.objectWillChange.sink {
            guard !invoked, model.session.state.desiredRing(1) == .position(CompactSession.ringSegment(for: 93)) else { return }
            invoked = true
            var policy = model.session.writeAuthorization; policy.allowsDisplay = false
            try? model.configureWriteAuthorization(policy)
            let nested = try? guiFeedback(model, "a.button.1", "indicator", .string("on"))
            #expect(nested?["isError"] as? Bool == true)
        }
        _ = try guiFeedback(model, "a.encoder.1", "value", .number(93))
        withExtendedLifetime(observer) {}
        #expect(invoked)
        #expect(try port.controls.snapshot(at: ProcessInfo.processInfo.systemUptime).latest_sequence == "1")
        #expect(try guiFeedback(model, "a.button.1", "indicator", .string("on"))["isError"] as? Bool == true)
    }

    @Test @MainActor func guiVirtualInactiveFeedbackRevocationPreservesBothSequencesFeedbackAndAllBudget() throws {
        let model = ConsoleModel(virtualSurfaceOnly: true, eventMonotonicClock: { 12 })
        try model.attachGUIVirtualSurface(inputCapacity: 64)
        let port = try #require(model.guiVirtualSurface)
        var policy = model.session.writeAuthorization; policy.allowsDisplay = false
        try model.configureWriteAuthorization(policy)
        let before = try port.controls.snapshot(at: 12)
        for _ in 0 ..< 61 {
            #expect(try guiFeedback(model, "b.encoder.1", "value", .number(93))["isError"] as? Bool == true)
        }
        let after = try port.controls.snapshot(at: 12)
        #expect(after.latest_sequence == before.latest_sequence && after.latest_input_sequence == before.latest_input_sequence)
        #expect(after.feedback == before.feedback && after.inputs == before.inputs)
        policy.allowsDisplay = true; try model.configureWriteAuthorization(policy)
        // All 60 original writes in the same injected second remain available.
        for index in 0 ..< 60 {
            #expect(try guiFeedback(model, "a.encoder.1", "value", .number(index))["isError"] as? Bool == false)
        }
        #expect(try guiFeedback(model, "a.encoder.1", "value", .number(60))["isError"] as? Bool == true)
        #expect(try port.controls.snapshot(at: 12).latest_sequence == "60")
    }

    @Test @MainActor func guiVirtualLanguageSelectionIsVolatileAndOrdinaryPreferencesRemainIndependent() throws {
        let name = "XTouchCompactDev.gui-language-test.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(AppLanguage.english.rawValue, forKey: "appLanguage")
        let ordinary = LanguageSettings(defaults: defaults), virtual = LanguageSettings(volatile: .english)
        #expect(ordinary.persistsSelection && !virtual.persistsSelection)
        virtual.selection = .traditionalChinese
        #expect(virtual.localizer.text("Settings") == "設定")
        #expect(defaults.string(forKey: "appLanguage") == AppLanguage.english.rawValue)
        #expect(LanguageSettings(volatile: .english).selection == .english)
        ordinary.selection = .simplifiedChinese
        #expect(LanguageSettings(defaults: defaults).selection == .simplifiedChinese)
        #expect(virtual.selection == .traditionalChinese)
    }

    @Test @MainActor func guiVirtualLayerGestureRetainsCanonicalMechanismPermission() throws {
        let model = try guiModel(), port = try #require(model.guiVirtualSurface)
        var policy = model.session.writeAuthorization; policy.allowsMechanisms = false
        try model.configureWriteAuthorization(policy)
        model.setLayer(.b)
        #expect(model.session.state.layer == .a && model.mock.layer == .a)
        #expect(!port.active && model.error != nil)
    }
#endif
