#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @MainActor final class FakeMIDIService: MIDIService {
        var onMessages: (([MIDIMessage]) -> Void)?
        var onConnection: ((CompactMIDIConnection) -> Void)?
        var sent: [MIDIMessage] = []
        var fails = false
        var starts = 0
        var sendAttempts = 0
        var actualInputID: Int32? = 1
        var actualOutputID: Int32? = 1
        var actualGeneration: UInt64 = 0
        func start() throws {
            starts += 1
        }

        func select(inputID _: Int32?, outputID _: Int32?) {}
        func send(_ message: MIDIMessage) throws {
            sendAttempts += 1
            if fails {
                throw CompactMIDIError.outputUnavailable
            }
            sent.append(message)
        }

        func sendPinned(_ message: MIDIMessage, inputID: Int32, outputID: Int32, generation: UInt64) throws {
            sendAttempts += 1
            guard actualInputID == inputID, actualOutputID == outputID, actualGeneration == generation else { throw CompactMIDIError.routeChanged }
            if fails {
                throw CompactMIDIError.outputUnavailable
            }
            sent.append(message)
        }

        func connect() {
            let endpoint = CompactMIDIEndpoint(id: 1, name: "Test Compact")
            onConnection?(CompactMIDIConnection(connectedInput: endpoint, connectedOutput: endpoint))
        }
    }

    @Test @MainActor func fakeServiceReconnectAndFailureNeverRecallMotors() {
        let service = FakeMIDIService()
        let model = ConsoleModel(midi: service, now: { Date(timeIntervalSince1970: 123) })
        #expect(service.starts == 1)
        model.setListenOnly(false); model.useHardware(true)
        #expect(model.error != nil)
        model.dismissNotification("runtime")
        #expect(model.error == nil)
        service.connect()
        #expect(!service.sent.contains {
            if case let .controlChange(_, n, _) = $0 {
                return (1 ... 9).contains(n)
            }; return false
        })
        model.faderChanged(1, value: 80)
        #expect(service.sent.last == .controlChange(channel: 0, number: 1, value: 80))
        service.fails = true
        model.faderChanged(1, value: 90)
        #expect(model.error != nil)
        service.fails = false
        service.onConnection?(CompactMIDIConnection())
        service.sent.removeAll()
        service.connect()
        #expect(!service.sent.contains {
            if case let .controlChange(_, n, _) = $0 {
                return (1 ... 9).contains(n)
            }; return false
        })
        service.onMessages?([.controlChange(channel: 5, number: 1, value: 1)])
        #expect(model.events.first?.ignored == true)
        #expect(model.events.first?.timestamp == Date(timeIntervalSince1970: 123))
        model.clearMonitor()
        #expect(model.events.isEmpty)
    }

    @Test @MainActor func explicitControlBeforeConnectionRecoversWithoutMotorRecall() {
        let service = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: service, isolated: true)
        model.useHardware(true)
        model.enableHardwareWriteback()
        #expect(model.error != nil)
        #expect(service.sent.isEmpty)
        service.connect()
        #expect(model.error == nil)
        #expect(!model.listenOnly)
        #expect(!service.sent.contains {
            if case let .controlChange(_, number, _) = $0 {
                (1 ... 9).contains(number)
            } else {
                false
            }
        })
    }

    @Test @MainActor func refusedProfileApplicationDoesNotChangeMockReadingsOrSavedProfile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, storageRoot: root, isolated: true)
        midi.connect(); model.setConsoleMode(.hardwareSend)
        midi.onMessages?([.controlChange(channel: 0, number: 1, value: 23),
                          .controlChange(channel: 0, number: 101, value: 127)])
        model.saveWorkspace()
        let saved = try Data(contentsOf: ProtectedWorkspaceStore(directory: root).url)
        let readings = model.liveHardwareValues
        let map = model.session.state.map
        model.clearMonitor()
        model.transmitChannel = 4; model.feedbackChannel = 2; model.observedLEDVariant = true
        model.configure()
        #expect(model.error as? CompactError == .fadersTouched)
        #expect(model.session.state.map.transmitChannel == map.transmitChannel)
        #expect(model.session.state.map.globalReceiveChannel == map.globalReceiveChannel)
        #expect(model.mock.map.transmitChannel == map.transmitChannel)
        #expect(model.mock.map.globalReceiveChannel == map.globalReceiveChannel)
        #expect(model.mock.lightProtocol == .manual)
        #expect(model.liveHardwareValues == readings)
        #expect(try Data(contentsOf: ProtectedWorkspaceStore(directory: root).url) == saved)
        #expect(!model.logs.contains { $0.key == "Profile applied; parameter values preserved" })
        #expect(midi.sent.isEmpty)
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 0)])
        model.configure()
        #expect(model.session.state.map.transmitChannel == 3)
        #expect(model.mock.map.transmitChannel == 3 && model.mock.map.globalReceiveChannel == 1)
        #expect(model.mock.lightProtocol == .observed114)
        #expect(model.liveHardwareValues == nil)
        #expect(midi.sent.first == .programChange(channel: 1, number: 0))
        #expect(try ProtectedWorkspaceStore(directory: root).load()?.profile.transmitChannel == 4)
    }

    @Test @MainActor func profileChangePreservesBanksAndTouchWithoutMotorRecall() {
        let model = ConsoleModel(startsMIDI: false)
        model.faderChanged(1, value: 40)
        model.setLayer(.b)
        model.faderChanged(1, value: 70)
        model.touchFader(1, isTouched: true)
        model.faderChanged(1, value: 90)
        model.clearMonitor()
        model.transmitChannel = 3
        model.feedbackChannel = 8
        model.configure()
        #expect(model.layer == .b)
        #expect(model.bank.faders[0] == 90)
        #expect(model.session.bank(.a).faders[0] == 40)
        #expect(model.session.state.isTouched(1))
        #expect(!model.session.state.isMotorPending(1))
        #expect(!model.events.contains {
            if case let .controlChange(_, n, _) = $0.message {
                return (1 ... 9).contains(n)
            }; return false
        })
        model.clearMonitor()
        model.touchFader(1, isTouched: false)
        #expect(!model.events.contains { $0.direction == .output && $0.control == .fader(1) })
    }
#endif
#if os(macOS)
    @Test @MainActor func persistenceUsesAppliedPortsAndNeverRewritesInvalidOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = ConsoleModel(startsMIDI: false, storageRoot: root, isolated: true)
        model.inputChoice = 123
        model.outputChoice = 456
        model.loadPreset(.audioExample)
        let store = ProtectedWorkspaceStore(directory: root)
        #expect(try store.load()?.profile.inputID == nil)
        model.selectPorts()
        #expect(try store.load()?.profile.inputID == 123)
        let restored = ConsoleModel(startsMIDI: false, storageRoot: root, isolated: true)
        #expect(restored.inputChoice == 123)
        #expect(restored.outputChoice == 456)
        #expect(restored.session.parameters.configuration == .audioExample)
        #expect(restored.session.parameters.values["a.Fader.1"] == -60)
        try Data("bad file".utf8).write(to: store.url)
        let damaged = ConsoleModel(startsMIDI: false, storageRoot: root, isolated: true)
        #expect(damaged.notifications.contains { $0.id == "storage" && $0.persistent })
        damaged.dismissNotification("storage")
        #expect(damaged.notifications.contains { $0.id == "storage" })
        #expect(try String(contentsOf: store.url, encoding: .utf8) == "bad file")
    }

    @Test @MainActor func inactiveHardwareTouchSurvivesModeSwitchAndReconnect() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect()
        midi.onMessages?([.controlChange(channel: 0, number: 111, value: 127)])
        #expect(model.session.state.isTouched(1))
        #expect(model.events.first?.ignored == false)
        model.faderChanged(1, value: 80) // Never command even the mock motor against known hardware touch.
        model.setListenOnly(false); model.useHardware(true)
        midi.sent.removeAll()
        model.faderChanged(1, value: 90)
        #expect(!midi.sent.contains {
            if case .controlChange(_, 1, _) = $0 {
                return true
            }; return false
        })
        midi.onConnection?(CompactMIDIConnection())
        midi.connect()
        #expect(model.session.state.isTouched(1))
        model.setParameter("a.Fader.1", value: 100, fromAgent: true)
        #expect(!midi.sent.contains {
            if case .controlChange(_, 1, _) = $0 {
                return true
            }; return false
        })
    }

    @Test @MainActor func transportSwitchDoesNotRecallDeferredMockIntent() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect()
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127)])
        model.faderChanged(1, value: 100)
        #expect(model.session.state.isMotorPending(1))
        model.setListenOnly(false); model.useHardware(true)
        midi.sent.removeAll()
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 0)])
        #expect(!midi.sent.contains {
            if case .controlChange(_, 1, _) = $0 {
                return true
            }; return false
        })
    }

    @Test @MainActor func mockProfileEditsKeepPhysicalPositions() {
        let model = ConsoleModel(startsMIDI: false)
        model.moveFader(1, value: 37)
        model.turnEncoder(1, delta: 53)
        model.transmitChannel = 4
        model.configure()
        #expect(model.mock.faders[0] == 37)
        #expect(model.mock.encoders[0] == 53)
    }

    @Test @MainActor func explicitRealignmentRefusesTouchThenRequiresRetryAfterRelease() throws {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect(); model.setListenOnly(false); model.useHardware(true)
        model.faderChanged(1, value: 90)
        midi.onMessages?([.controlChange(channel: 0, number: 111, value: 127)])
        #expect(model.session.state.layerMismatch)
        #expect(model.notifications.contains { $0.id == "layer" })
        midi.sent.removeAll()
        let realign = try #require(model.panelIntents.realignLayer)
        realign()
        #expect(midi.sent.isEmpty)
        #expect(model.session.state.layerMismatch)
        #expect(model.session.state.isTouched(1))
        midi.onMessages?([.controlChange(channel: 0, number: 111, value: 0)])
        #expect(midi.sent.isEmpty)
        realign()
        #expect(midi.sent.contains(.programChange(channel: 0, number: 0)))
        #expect(!midi.sent.contains {
            if case let .controlChange(_, n, _) = $0 {
                return (1 ... 9).contains(n)
            }; return false
        })
        #expect(!model.session.state.layerMismatch)
        #expect(model.session.state.observedLayer == nil) // Assertion is not a position/layer observation.
        #expect(!model.session.state.isTouched(1))
        #expect(!model.notifications.contains { $0.id == "layer" })
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 0)])
        midi.sent.removeAll()
        model.faderChanged(1, value: 90)
        #expect(midi.sent.contains(.controlChange(channel: 0, number: 1, value: 90))) // Explicit reassertion is not suppressed by old send history.
    }
#endif
#if os(macOS)
    @Test @MainActor func parameterValuesPersistAcrossLaunchWithoutMotorRecall() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ConsoleModel(startsMIDI: false, storageRoot: root, isolated: true)
        let store = ProtectedWorkspaceStore(directory: root)
        first.advanceAgents()
        #expect(try store.load() == nil) // Defaults alone never create a workspace file.
        first.setParameter("a.Fader.1", value: 100)
        first.setParameter("a.Encoder.2", value: 64)
        #expect(first.parameterValuesDirty)
        first.flushHardwareValues()
        #expect(!first.parameterValuesDirty)
        #expect(try store.load()?.parameterValues?["a.Fader.1"] == 100)

        let midi = FakeMIDIService()
        let restored = ConsoleModel(startsMIDI: false, midi: midi, storageRoot: root, isolated: true)
        #expect(restored.session.parameters.values["a.Fader.1"] == 100)
        #expect(restored.session.parameters.values["a.Encoder.2"] == 64)
        #expect(restored.bank.faders[0] == 100)
        // Restored intent: no motor command on launch or on hardware connection.
        #expect(!restored.events.contains { $0.direction == .output && $0.control == .fader(1) })
        midi.connect()
        restored.setListenOnly(false); restored.useHardware(true)
        #expect(!midi.sent.contains {
            if case .controlChange(_, 1 ... 9, _) = $0 {
                return true
            }
            return false
        })
        #expect(!restored.session.state.isMotorPending(1))
    }
#endif
