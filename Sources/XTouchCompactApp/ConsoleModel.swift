#if os(macOS)
    import AgentPlugin
    import AppKit
    import Foundation
    import Network
    import OutputRemoteBinding
    import RemoteToolContracts
    import SurfacePluginContracts
    import SwiftUI
    import UniformTypeIdentifiers
    import XTouchCompactCore
    import XTouchCompactLocalization

    private struct ErrorMessageBuilder {
        func text(_ key: String, _ arguments: String..., localizedArgumentIndices: Set<Int> = []) -> LocalizedMessage {
            LocalizedMessage(key: key, arguments: arguments, localizedArgumentIndices: localizedArgumentIndices)
        }
    }

    /// SwiftUI state is deliberately separate from the value-only/testable protocol session.
    @MainActor
    final class ConsoleModel: ObservableObject {
        @Published private(set) var bank = CompactParameterBank()
        @Published private(set) var layer: CompactLayer = .a
        @Published private(set) var connection = CompactMIDIConnection()
        @Published private(set) var events: [MonitorEvent] = []
        @Published private(set) var mockMIDIInAt: Date?
        @Published private(set) var mockMIDIOutAt: Date?
        /// Last simulated expression-pedal movement; drives the mock FOOT EXP pulse only.
        @Published private(set) var mockExpressionAt: Date?
        @Published private(set) var hardwareValueCache: HardwareValueCache?
        @Published private(set) var liveHardwareValues: HardwareValueCache?
        @Published private(set) var reportedHardwarePresses: [CompactControl: Bool] = [:]
        private var hardwareValuesDirty = false
        /// Parameter values last written to disk; differences are flushed with the runtime tick.
        private var savedParameterValues: [String: Double]?
        private var hardwareValuesSavedAt: TimeInterval = 0
        var logs: [LocalizedMessage] {
            events.map(\.text)
        }

        @Published private(set) var notifications: [ConsoleNotification] = []
        @Published private(set) var hardwareMode = false
        /// Host delivery state only, not physical acknowledgement. True after attachment,
        /// mode/profile changes or failed/suppressed feedback until a full explicit sync.
        @Published private(set) var hardwareFeedbackNeedsSync = true
        /// Session-only safety choice: every launch starts passively. Never rewrites a device profile.
        @Published private(set) var listenOnly = true
        @Published private(set) var isObservingHardware = false
        @Published private(set) var hardwareObserver = CompactInputObserver()
        @Published private(set) var nonMotorTests = NonMotorTestState()
        @Published private(set) var observationStartedAt: Date?
        @Published private(set) var lastReviewExport: InputReviewExportReceipt?
        @Published private(set) var capturePath: String?
        private var lastCaptureURL: URL?
        private var observationInputID: Int32?
        private var monitorCapture: MonitorCapture?
        @Published var transmitChannel = 1
        @Published var feedbackChannel = 1
        @Published var inputChoice: Int32 = 0
        @Published var outputChoice: Int32 = 0
        @Published var observedLEDVariant = false
        @Published private(set) var error: (any Error)? {
            didSet {
                notifications.removeAll { $0.id == "runtime" }
                if error != nil {
                    notifications.append(ConsoleNotification(id: "runtime", level: .error, persistent: false))
                }
            }
        }

        private(set) var plugins = try! CompactPluginHost.agent()
        var agents: AgentPresentation {
            AgentPresentation(plugins)
        }

        let mcp = LocalMCPServer()
        let mcpPort: UInt16 = 8765
        let isolated: Bool
        private let memoryToken = UUID().uuidString + UUID().uuidString
        func accessToken() throws -> String {
            isolated ? memoryToken : try MCPTokenStore().token()
        }

        @Published var mcpEnabled = false
        @Published var mcpWritesAllowed = false
        @Published var mcpSimulationControlAllowed = false
        /// Session-only, default off: Agent parameter writes may move motors only when granted.
        @Published var mcpMotorWritesAllowed = false
        /// Session-only panel highlight; never persisted or sent to the device.
        @Published var highlightedGroup: String?
        private var surfaceWriteBudget = SurfaceWriteBudget()
        @Published var oscHost = "127.0.0.1"
        @Published var oscPort: UInt16 = 9000
        @Published var oscParameter = "a.Fader.1"
        @Published var oscEnabled = false
        @Published var oscOutput = 0.0
        /// Authenticated telemetry facts are independent from requests and sent packets.
        private(set) var trustedOSCActual: (value: Double, time: Double)?
        private(set) var trustedOSCHeartbeat: Double?
        let oscTransport: any OSCTransport
        private var runtimeTask: Task<Void, Never>?
        var runtimeTime: TimeInterval {
            runtimeClock()
        }

        private var agentOutput = false

        private let midi: any MIDIService
        private var appliedInputID: Int32?
        private var appliedOutputID: Int32?
        private let store: ProtectedWorkspaceStore?
        private let now: () -> Date
        private let runtimeClock: () -> TimeInterval
        private let evidenceWriterFactory: (URL) throws -> any EvidenceWriting
        private(set) var session: CompactSession
        private(set) var mock: MockXTouchCompact

        init(startsMIDI: Bool = true, midi: (any MIDIService)? = nil, now: (() -> Date)? = nil, storageRoot: URL? = nil, isolated: Bool = false, oscTransport: (any OSCTransport)? = nil,
             evidenceWriterFactory: @escaping (URL) throws -> any EvidenceWriting = { try ExclusiveEvidenceFile(url: $0) })
        {
            self.midi = midi ?? CoreMIDIService()
            self.oscTransport = oscTransport ?? NetworkOSCTransport()
            self.now = now ?? Date.init
            runtimeClock = now.map { injected in { injected().timeIntervalSince1970 } } ?? { ProcessInfo.processInfo.systemUptime }
            self.evidenceWriterFactory = evidenceWriterFactory
            self.isolated = isolated
            store = storageRoot.map(ProtectedWorkspaceStore.init(directory:))
            let map = try! FactoryStandardMap() // Constant channels are valid by construction.
            session = CompactSession(map: map, lightProtocol: .manual)
            mock = MockXTouchCompact(map: map, lightProtocol: .manual)
            self.midi.onMessages = { [weak self] messages in self?.receive(messages) }
            self.midi.onConnection = { [weak self] snapshot in
                guard let self else { return }
                let routeChanged = snapshot.isConnected != connection.isConnected
                    || snapshot.connectedInput?.id != connection.connectedInput?.id
                    || snapshot.connectedOutput?.id != connection.connectedOutput?.id
                    || snapshot.generation != connection.generation
                if routeChanged {
                    liveHardwareValues = nil
                    reportedHardwarePresses = [:]
                }
                if nonMotorTests.approval != nil {
                    lockNonMotorTests("Connection changed; test output locked.")
                }
                connection = snapshot
                if snapshot.isConnected, let connectionError = error as? ConsoleError, connectionError == .noConnection {
                    error = nil
                }
                if isObservingHardware, let newInput = snapshot.connectedInput?.id {
                    if let observationInputID, observationInputID != newInput {
                        resetHardwareObservation()
                    }
                    observationInputID = newInput
                }
                appendEvent(MonitorEvent(timestamp: self.now(), direction: nil, source: .application, message: nil,
                                         control: nil, hostLayer: layer, ignored: false, text: LocalizedMessage("MIDI connection changed"), connection: snapshot))
                if routeChanged {
                    hardwareFeedbackNeedsSync = true
                    if hardwareMode {
                        // Disconnect/reconnect/endpoint replacement is never an output action.
                        apply { try $0.connect(assertLayer: false) }
                    }
                }
            }
            if let store {
                do {
                    if let saved = try store.load() {
                        hardwareValueCache = saved.hardwareValues
                        transmitChannel = saved.profile.transmitChannel
                        feedbackChannel = saved.profile.receiveChannel
                        observedLEDVariant = saved.profile.ledProtocol == .observed114
                        inputChoice = saved.profile.inputID ?? 0
                        outputChoice = saved.profile.outputID ?? 0
                        appliedInputID = saved.profile.inputID
                        appliedOutputID = saved.profile.outputID
                        let map = try FactoryStandardMap(transmitChannel: UInt8(transmitChannel - 1), globalReceiveChannel: UInt8(feedbackChannel - 1))
                        _ = try session.reconfigure(map: map, lightProtocol: saved.profile.ledProtocol)
                        _ = try session.loadConfiguration(saved.configuration, resetValues: true)
                        if let values = saved.parameterValues {
                            // Host intent only. The following connect() sends rings/LEDs; motors
                            // stay where they are until the user explicitly recalls them.
                            _ = try session.restoreParameterValues(values)
                        }
                        savedParameterValues = session.parameters.values
                        mock = MockXTouchCompact(map: map, lightProtocol: saved.profile.ledProtocol)
                    }
                } catch { storageFailure(error) }
                // Without a saved file, defaults are not a change worth creating one for.
                if savedParameterValues == nil {
                    savedParameterValues = session.parameters.values
                }
            }
            if startsMIDI {
                do { try self.midi.start() } catch { self.error = error }
            }
            self.midi.select(inputID: inputChoice == 0 ? nil : inputChoice, outputID: outputChoice == 0 ? nil : outputChoice)
            apply { try $0.connect() }
        }

        func useHardware(_ enabled: Bool) {
            if isObservingHardware, !enabled {
                endHardwareObservation()
            }
            guard hardwareMode != enabled else { return }
            session.prepareTransportSwitch(inputTouches: enabled ? [] : mock.touchedFaders)
            if notifications.contains(where: { $0.id == "layer" }) {
                notifications.removeAll { $0.id == "layer" }
            }
            hardwareMode = enabled
            mockMIDIInAt = nil
            mockMIDIOutAt = nil
            mockExpressionAt = nil
            if enabled {
                guard connection.isConnected else {
                    error = ConsoleError.noConnection
                    return
                }
                session.setInputTouches([])
                hardwareFeedbackNeedsSync = true
                apply { try $0.connect(assertLayer: false) }
            } else {
                error = nil
                session.setInputTouches(mock.touchedFaders)
                apply { try $0.selectLayer(layer) }
                log(LocalizedMessage("Switched to deterministic mock surface"))
            }
        }

        /// Single entry point for the mode bar. No transition sends MIDI to the controller:
        /// entering hardware always goes through listen-only first, and enabling sending does
        /// not replay anything. The user syncs lights explicitly afterwards.
        func setConsoleMode(_ mode: ConsoleMode) {
            switch mode {
            case .mock:
                useHardware(false)
            case .hardwareListen:
                // Choosing a mode always returns to the console, also from the input-check tool.
                if isObservingHardware {
                    endHardwareObservation()
                }
                setListenOnly(true)
                if !hardwareMode {
                    useHardware(true)
                }
            case .hardwareSend:
                if !hardwareMode {
                    setListenOnly(true)
                    useHardware(true)
                }
                guard connection.isConnected else { return } // Stay passive until a controller is there.
                enableHardwareWriteback()
            }
        }

        func setListenOnly(_ enabled: Bool) {
            if enabled {
                lockNonMotorTests()
            }
            guard !isObservingHardware || enabled, listenOnly != enabled else { return }
            listenOnly = enabled
            // No replay or layer assertion on either transition. Preserve hardware touch/layer evidence.
            if hardwareMode {
                hardwareFeedbackNeedsSync = true
                session.discardPendingMotorWrites(); session.invalidateTransportFeedback(); updateBank()
            }
        }

        func beginHardwareObservation() {
            setListenOnly(true)
            session.prepareTransportSwitch(inputTouches: [])
            hardwareMode = true
            hardwareObserver = CompactInputObserver()
            observationInputID = connection.connectedInput?.id
            observationStartedAt = now(); lastReviewExport = nil
            if capturePath == nil {
                lastCaptureURL = nil
            }
            isObservingHardware = true
            if oscEnabled {
                setOSCEnabled(false)
            }
        }

        func endHardwareObservation() {
            lockNonMotorTests()
            isObservingHardware = false
            // Returning to the console retains passive output and all safety ownership.
        }

        /// Explicitly leave passive diagnostics for normal writes; enabling itself sends nothing.
        func enableHardwareWriteback() {
            guard hardwareMode else { return }
            endHardwareObservation()
            setListenOnly(false)
        }

        func resetHardwareObservation() {
            lockNonMotorTests("Observation reset; test output locked.")
            hardwareObserver = CompactInputObserver()
            observationStartedAt = now(); lastReviewExport = nil
            if capturePath == nil {
                lastCaptureURL = nil
            }
        }

        // MARK: - Explicit nonmotor diagnostics

        private var nonMotorContext: NonMotorTransportContext {
            NonMotorTransportContext(inputID: connection.connectedInput?.id, outputID: connection.connectedOutput?.id,
                                     recording: monitorCapture != nil, generation: connection.generation)
        }

        func armNonMotorTests(_ prerequisites: NonMotorTestPrerequisites) {
            lockNonMotorTests()
            do {
                guard hardwareMode, isObservingHardware else { throw NonMotorTestError.permissionRevoked }
                var candidate = nonMotorTests
                try candidate.arm(prerequisites, context: nonMotorContext, id: UUID().uuidString)
                guard let approval = candidate.approval else { return }
                recordNonMotorAudit(NonMotorTestAudit(phase: "permission-granted", approval: approval))
                guard checkpointNonMotorEvidence() else { return }
                nonMotorTests = candidate
                session.discardPendingMotorWrites()
                listenOnly = false
                error = nil
            } catch { self.error = error }
        }

        func lockNonMotorTests(_ reason: String = "Test output locked.") {
            guard nonMotorTests.approval != nil else { return }
            let audit = nonMotorTests.lock(reason)
            listenOnly = true; session.discardPendingMotorWrites()
            if let audit {
                recordNonMotorAudit(audit)
            }
        }

        func performNonMotorTest(_ command: NonMotorTestCommand) {
            do {
                guard hardwareMode, isObservingHardware else { throw NonMotorTestError.permissionRevoked }
                let request = try nonMotorTests.authorize(command, context: nonMotorContext)
                let id = UUID().uuidString
                nonMotorTests.add(request, id: id, at: now())
                let audit = NonMotorTestAudit(phase: "command-requested", approval: request.approval,
                                              attemptID: id, command: command, message: request.message)
                recordNonMotorAudit(audit)
                guard checkpointNonMotorEvidence() else { return }
                let delivery = send([request.message], authorizedTest: request, testAudit: audit)
                nonMotorTests.delivered(id, status: delivery)
                if monitorCapture != nil {
                    _ = checkpointNonMotorEvidence()
                }
                session.invalidateNonMotorFeedback()
            } catch { self.error = error; lockNonMotorTests() }
        }

        func previewNonMotorTest(_ command: NonMotorTestCommand, receiveChannel: UInt8?) {
            do {
                try nonMotorTests.preview(command, channel: nonMotorTests.approval?.prerequisites.receiveChannel ?? receiveChannel)
                error = nil
            } catch { self.error = error }
        }

        func recordNonMotorObservation(_ id: String, result: NonMotorReportedResponse, note: String) {
            do {
                guard isObservingHardware, monitorCapture != nil else { throw NonMotorTestError.recordingRequired }
                var candidate = nonMotorTests
                let audit = try candidate.recordObservation(id, result: result, note: note, context: nonMotorContext)
                recordNonMotorAudit(audit)
                guard checkpointNonMotorEvidence() else { return }
                nonMotorTests = candidate
                error = nil
            } catch { self.error = error }
        }

        private func recordNonMotorAudit(_ audit: NonMotorTestAudit) {
            appendEvent(MonitorEvent(timestamp: now(), direction: nil, source: .application, message: nil,
                                     control: audit.command?.control, hostLayer: layer, ignored: false,
                                     text: LocalizedMessage("Nonmotor test: %@", audit.phase), nonMotorTest: audit))
        }

        private func checkpointNonMotorEvidence() -> Bool {
            guard let monitorCapture else { return false }
            do { try monitorCapture.checkpoint(); return true }
            catch { captureFailed(error); return false }
        }

        private func captureFailed(_ failure: any Error) {
            monitorCapture = nil; capturePath = nil; error = failure
            if nonMotorTests.approval != nil {
                _ = nonMotorTests.lock("Recording failed; test output locked.")
                listenOnly = true; session.discardPendingMotorWrites()
            }
        }

        func configure() {
            lockNonMotorTests("Profile changed; test output locked.")
            do {
                guard (1 ... 16).contains(transmitChannel), (1 ... 16).contains(feedbackChannel) else {
                    throw CompactError.invalidChannel(16)
                }
                let map = try FactoryStandardMap(
                    transmitChannel: UInt8(transmitChannel - 1),
                    globalReceiveChannel: UInt8(feedbackChannel - 1)
                )

                let variant: ButtonLightProtocol = observedLEDVariant ? .observed114 : .manual
                let inputChannelChanged = session.state.map.transmitChannel != map.transmitChannel
                var candidate = session
                let messages = try candidate.reconfigure(map: map, lightProtocol: variant)
                try validateHardwareLayerAssertion(messages)
                // Commit both protocol peers and their reading scope only after validation.
                session = candidate
                mock = mock.reconfigured(map: map, lightProtocol: variant)
                if inputChannelChanged {
                    liveHardwareValues = nil
                    reportedHardwarePresses = [:]
                }
                send(messages)
                updateBank()
                if isObservingHardware, inputChannelChanged {
                    resetHardwareObservation()
                }
                log(LocalizedMessage("Profile applied; parameter values preserved"))
                saveWorkspace()
            } catch { self.error = error }
        }

        func loadReferenceArmExample(using localizer: Localizer = Localizer(language: .system)) {
            do {
                var parameters = try CompactPluginHost.referenceArmParameters()
                for index in parameters.indices {
                    parameters[index].name = localizer.text(parameters[index].name)
                    parameters[index].group = localizer.text(parameters[index].group)
                }
                loadPreset(SurfaceConfiguration(parameters: parameters, assignments: [], version: 2))
            } catch { self.error = error }
        }

        func installOptionalPlugins(_ selection: Set<OptionalBusinessPlugin>) {
            do {
                var next = plugins
                try next.installOptional(selection, lifetimeID: UUID().uuidString, at: runtimeTime)
                try commitPlugins(next)
            } catch { self.error = error }
        }

        /// Only a trusted host telemetry adapter may deliver destination measurements.
        /// There is deliberately no UI or MCP operation for manufacturing these facts.
        func receiveTrustedOSCActual(_ value: Double, at time: Double) {
            guard time.isFinite else {
                setOSCEnabled(false)
                notificationsForOSC("OSC output stopped: telemetry timestamp is invalid.")
                return
            }
            trustedOSCActual = (value, time)
            guard var binding = plugins.binding(OutputRemoteBinding.defaultInstanceID, as: OutputRemoteBinding.self) else { return }
            binding.plugin.receiveActual([.init(id: "output.value", value: value, receivedAt: time)])
            do {
                var next = plugins
                try next.replaceBinding(binding, at: runtimeTime, event: nil)
                try commitPlugins(next)
            } catch { self.error = error }
        }

        func receiveTrustedOSCHeartbeat(at time: Double) {
            guard time.isFinite else {
                setOSCEnabled(false)
                notificationsForOSC("OSC output stopped: telemetry timestamp is invalid.")
                return
            }
            trustedOSCHeartbeat = time
            guard var binding = plugins.binding(OutputRemoteBinding.defaultInstanceID, as: OutputRemoteBinding.self) else { return }
            binding.plugin.receiveHeartbeat(at: time)
            do {
                var next = plugins
                try next.replaceBinding(binding, at: runtimeTime, event: nil)
                try commitPlugins(next)
            } catch { self.error = error }
        }

        func clearTrustedOSCTelemetry() {
            trustedOSCActual = nil; trustedOSCHeartbeat = nil
        }

        func agentPrimary(_ slot: Int, fromAgent: Bool = false) {
            invokePluginAction(PluginConfigurationAdapter.agentAction(slot), origin: fromAgent ? .remote : .interface)
        }

        func invokePluginAction(_ ref: ActionReference, origin: InputOrigin) {
            do { try performPluginAction(ref, origin: origin) }
            catch { self.error = error }
        }

        func performSurfaceCall(_ name: String, arguments: JSONValue) throws -> JSONValue {
            if plugins.remoteTools.first(where: { $0.name == name })?.isMutation == true {
                guard mcpWritesAllowed else { throw RemoteFailure(code: "permissionDenied") }
                if name == "surface_robot_advance" || name == "surface_chassis_advance" {
                    throw RemoteFailure(code: "permissionDenied", fields: ["reason": .string("realtimeClock")])
                }
                if name == "surface_robot_reset" || name == "surface_chassis_reset" {
                    guard mcpSimulationControlAllowed else { throw RemoteFailure(code: "permissionDenied", fields: ["reason": .string("simulationControl")]) }
                }
                guard surfaceWriteBudget.consume(at: runtimeTime) else { throw RemoteFailure(code: "permissionDenied", fields: ["reason": .string("writeRate")]) }
            }
            var next = plugins
            let response = try next.callRemote(name, arguments: arguments,
                                               context: .init(time: runtimeTime, controlToken: UUID().uuidString, permitsOutputEnable: false))
            try commitPlugins(next)
            return response
        }

        func performPluginAction(_ ref: ActionReference, origin: InputOrigin) throws {
            agentOutput = origin == .remote
            defer { agentOutput = false }
            var next = plugins
            try next.handle(.invoke(ref, origin: origin), pluginID: ref.pluginID, at: runtimeTime)
            try commitPlugins(next)
        }

        func commitPlugins(_ next: CompactPluginHost) throws {
            let changed = next.snapshots != plugins.snapshots || next.businessPresentations != plugins.businessPresentations
            if changed {
                objectWillChange.send()
            }
            plugins = next
            guard changed else { return }
            let indicators = next.feedbackIndicators
            apply { try $0.updateIndicators(indicators) }
        }

        func advanceAgents() {
            if hardwareValuesDirty, runtimeTime - hardwareValuesSavedAt >= 1 {
                flushHardwareValues()
            } else if parameterValuesDirty, runtimeTime - hardwareValuesSavedAt >= 1 {
                hardwareValuesSavedAt = runtimeTime
                saveWorkspace()
            }
            tickOSC()
            do {
                var next = plugins
                try next.advance(to: runtimeTime)
                try commitPlugins(next)
            } catch { self.error = error }
        }

        func startRuntime() {
            guard runtimeTask == nil else { return }
            runtimeTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(250)) } catch { break }
                    self?.advanceAgents()
                }
            }
        }

        func stopRuntime() {
            runtimeTask?.cancel(); runtimeTask = nil; setOSCEnabled(false)
        }

        deinit { runtimeTask?.cancel() }

        func setParameter(_ id: String, value: Double, fromAgent: Bool = false) {
            do {
                let messages = try session.setParameter(id, value: value, fromAgent: fromAgent,
                                                        drivesMotors: !fromAgent || mcpMotorWritesAllowed)

                if fromAgent {
                    sendAgentFeedback(messages)
                } else {
                    send(messages); updateBank()
                }
            } catch { self.error = error }
        }

        @Published private(set) var pendingPreset: SurfaceConfiguration?

        func loadPreset(_ configuration: SurfaceConfiguration) {
            do {
                try configuration.validate()
                if session.hasNonDefaultValues {
                    pendingPreset = configuration
                } else {
                    replaceWithPreset(configuration)
                }
            } catch { self.error = error }
        }

        func cancelLoadPreset() {
            pendingPreset = nil
        }

        /// Only the explicitly confirmed UI action calls this when a replacement is pending.
        func confirmLoadPreset() {
            guard let configuration = pendingPreset else { return }
            replaceWithPreset(configuration)
        }

        private func replaceWithPreset(_ configuration: SurfaceConfiguration) {
            do {
                let messages = try session.loadConfiguration(configuration, resetValues: true)
                pendingPreset = nil
                send(messages); updateBank(); saveWorkspace()
            } catch { self.error = error }
        }

        func applyConfiguration(_ configuration: SurfaceConfiguration) {
            do {
                let messages = try session.loadConfiguration(configuration)
                pendingPreset = nil
                send(messages); updateBank(); saveWorkspace()
            } catch { self.error = error }
        }

        func resetParameterValues() {
            do { try send(session.loadConfiguration(session.parameters.configuration, resetValues: true)); updateBank(); saveWorkspace() }
            catch { self.error = error }
        }

        func selectPorts() {
            lockNonMotorTests("Connection changed; test output locked.")
            appliedInputID = inputChoice == 0 ? nil : inputChoice
            appliedOutputID = outputChoice == 0 ? nil : outputChoice
            midi.select(inputID: inputChoice == 0 ? nil : inputChoice,
                        outputID: outputChoice == 0 ? nil : outputChoice)
            saveWorkspace()
        }

        func realignCurrentLayer() {
            setLayer(layer)
        }

        func setLayer(_ next: CompactLayer) {
            lockNonMotorTests()
            apply { session in
                guard hardwareMode else { return try session.selectLayer(next) }
                var messages = try session.selectHostLayer(next)
                if !listenOnly {
                    messages.insert(session.state.map.selectLayer(next), at: 0)
                }
                return messages
            }
            layer = session.state.layer
            updateBank()
        }

        func recallMotors() {
            apply { try $0.recallFaders() }
        }

        func faderChanged(_ index: Int, value: Double) {
            apply { try $0.setFader(index, value: UInt8(value.rounded())) }
            updateBank()
        }

        func encoderChanged(_ index: Int, value: Double) {
            apply { try $0.setEncoder(index, value: UInt8(value.rounded())) }
            updateBank()
        }

        func pressButton(_ index: Int) {
            guard hardwareMode else {
                performMockGesture { try $0.pressButton(index, isDown: true) }
                return
            }
            do {
                let update = try session.activateButton(index)
                send(update.feedback)
                for ref in update.actionIntents {
                    invokePluginAction(ref, origin: .interface)
                }
                updateBank()
            } catch { self.error = error }
        }

        func moveFader(_ index: Int, value: UInt8) {
            if hardwareMode {
                faderChanged(index, value: Double(value))
            } else {
                performMockGesture { try $0.moveFader(index, value: value) }
            }
        }

        func touchFader(_ index: Int, isTouched: Bool) {
            performMockGesture { try $0.touchFader(index, isTouched: isTouched) }
        }

        func turnEncoder(_ index: Int, delta: Int) {
            if hardwareMode {
                guard (1 ... CompactGeometry.encoderCount).contains(index) else { return }
                let current = Int(bank.encoders[index - 1])
                encoderChanged(index, value: Double(min(max(current + min(max(delta, -127), 127), 0), 127)))
            } else {
                performMockGesture { try $0.turnEncoder(index, delta: delta) }
            }
        }

        func pushEncoder(_ index: Int, isDown: Bool) {
            performMockGesture { try $0.pushEncoder(index, isDown: isDown) }
        }

        /// Preview fixtures only: press the mock's physical A/B selector (no MIDI is emitted,
        /// exactly like the device). The host learns the layer from the next input.
        func setMockPhysicalLayerForPreview(_ layer: CompactLayer) {
            guard !hardwareMode else { return }
            mock.selectPhysicalLayer(layer)
        }

        /// Simulated rear-panel accessories. Mock only: a real pedal is physical input.
        func moveExpression(_ value: UInt8) {
            guard !hardwareMode else { return }
            mockExpressionAt = now()
            performMockGesture { try $0.moveExpression(value) }
        }

        func pressFootswitch(isDown: Bool) {
            guard !hardwareMode else { return }
            performMockGesture { $0.pressFootswitch(isDown: isDown) }
        }

        func releaseButton(_ index: Int) {
            performMockGesture { try $0.pressButton(index, isDown: false) }
        }

        private func performMockGesture(_ operation: (inout MockXTouchCompact) throws -> [MIDIMessage]) {
            guard !hardwareMode else { return }
            do { try receive(operation(&mock), fromMock: true) }
            catch { self.error = error }
        }

        private func recordHardwareInput(_ input: CompactInput) {
            guard let inputID = connection.connectedInput?.id else { return }
            let channel = session.state.map.transmitChannel
            if hardwareValueCache?.inputID != inputID || hardwareValueCache?.transmitChannel != channel {
                hardwareValueCache = HardwareValueCache(inputID: inputID, transmitChannel: channel)
            }
            if liveHardwareValues?.inputID != inputID || liveHardwareValues?.transmitChannel != channel {
                liveHardwareValues = HardwareValueCache(inputID: inputID, transmitChannel: channel)
            }
            let previous = hardwareValueCache
            let timestamp = now()
            hardwareValueCache?.record(input, at: timestamp)
            liveHardwareValues?.record(input, at: timestamp)
            if previous != hardwareValueCache {
                hardwareValuesDirty = true
            }
            if let pressed = input.isPressed {
                reportedHardwarePresses[input.control] = pressed
            }
        }

        private func receive(_ messages: [MIDIMessage], fromMock: Bool = false) {
            if fromMock, !messages.isEmpty {
                mockMIDIOutAt = now()
            }
            for message in messages {
                let event = session.state.map.decode(message)
                if !fromMock, let event {
                    recordHardwareInput(event)
                }
                if !fromMock, let event, case let .faderTouch(index) = event.control {
                    session.setSafetyTouch(index, touched: event.isPressed == true)
                }
                let safetyOnly = !fromMock && !hardwareMode && event.map {
                    if case .faderTouch = $0.control {
                        return true
                    }; return false
                } == true
                record(message, direction: .input, source: fromMock ? .mock : .hardware,
                       ignored: !safetyOnly && (hardwareMode == fromMock || event == nil))
                if !fromMock, isObservingHardware {
                    hardwareObserver.receive(message, map: session.state.map, at: now())
                }
            }
            if isObservingHardware, !fromMock {
                session.observeInputs(messages)
                return
            }
            guard hardwareMode != fromMock else { return }
            do {
                let update = try session.receive(messages)
                send(update.feedback)
                if session.state.layerMismatch {
                    if !notifications.contains(where: { $0.id == "layer" }) {
                        notifications.append(ConsoleNotification(id: "layer", level: .warning, message: LocalizedMessage("Device layer differs from the host; motor output is blocked."), persistent: false))
                    }
                } else if notifications.contains(where: { $0.id == "layer" }) {
                    notifications.removeAll { $0.id == "layer" }
                }
                for ref in update.actionIntents {
                    invokePluginAction(ref, origin: fromMock ? .interface : .hardware)
                }
                if !update.inputs.isEmpty {
                    updateBank()
                }
            } catch { self.error = error }
        }

        func apply(_ operation: (inout CompactSession) throws -> [MIDIMessage]) {
            do {
                var next = session
                let messages = try operation(&next)
                try validateHardwareLayerAssertion(messages)
                session = next
                send(messages)
                updateBank()
            } catch { self.error = error }
        }

        private func validateHardwareLayerAssertion(_ messages: [MIDIMessage]) throws {
            guard hardwareMode, !listenOnly, messages.contains(where: {
                if case .programChange = $0 {
                    return true
                }; return false
            }) else { return }
            try session.state.validateLayerAssertion()
        }

        // MARK: - Single outgoing MIDI boundary

        @discardableResult
        private func send(_ messages: [MIDIMessage], authorizedTest: AuthorizedNonMotorTest? = nil,
                          testAudit: NonMotorTestAudit? = nil) -> MonitorEvent.Delivery
        {
            let route = connection // Pin the entire batch, including synchronous service callbacks.
            let source: MonitorEvent.Source = agentOutput ? .agent : (hardwareMode ? .hardware : .mock)
            var testAllowed = false
            if let authorizedTest {
                do {
                    guard hardwareMode, isObservingHardware else { throw NonMotorTestError.permissionRevoked }
                    try nonMotorTests.gate.validate(authorizedTest, messages: messages, context: nonMotorContext)
                    testAllowed = true
                } catch { self.error = error; lockNonMotorTests() }
            }
            if authorizedTest != nil && !testAllowed || hardwareMode && (listenOnly || isObservingHardware && !testAllowed) {
                if hardwareMode, !messages.isEmpty {
                    hardwareFeedbackNeedsSync = true
                }
                session.discardPendingMotorWrites(); session.invalidateTransportFeedback()
                for message in messages {
                    record(message, direction: .output, source: source, ignored: true, delivery: .suppressed,
                           nonMotorTest: testAudit?.withDelivery(.suppressed), controlOverride: authorizedTest?.command.control)
                }
                return .suppressed
            }
            // Also covers approved diagnostic layer tests and callers outside apply().
            // Reject the whole batch; no queued layer operation survives this refusal.
            do { try validateHardwareLayerAssertion(messages) }
            catch { self.error = error; return .suppressed }
            for message in messages {
                guard hardwareMode else {
                    mock.receive(message)
                    mockMIDIInAt = now()
                    record(message, direction: .output, source: source, delivery: .sent)
                    continue
                }
                if case let .controlChange(_, number, _) = message, (1 ... 9).contains(number) {
                    liveHardwareValues?.invalidateFader(Int(number))
                }
                do {
                    if let authorizedTest {
                        try midi.sendPinned(message, inputID: authorizedTest.approval.inputID, outputID: authorizedTest.approval.outputID, generation: authorizedTest.approval.generation)
                    } else {
                        guard let inputID = route.connectedInput?.id,
                              let outputID = route.connectedOutput?.id else { throw ConsoleError.noConnection }
                        try midi.sendPinned(message, inputID: inputID, outputID: outputID, generation: route.generation)
                    }
                    if case .programChange = message {
                        session.didTransmitLayerAssertion()
                    }
                    record(message, direction: .output, source: source, delivery: .sent,
                           nonMotorTest: testAudit?.withDelivery(.sent), controlOverride: authorizedTest?.command.control)
                } catch {
                    self.error = error
                    record(message, direction: .output, source: source, ignored: true, delivery: .failed,
                           nonMotorTest: testAudit?.withDelivery(.failed), controlOverride: authorizedTest?.command.control)
                    hardwareFeedbackNeedsSync = true
                    session.discardPendingMotorWrites()
                    session.invalidateTransportFeedback()
                    lockNonMotorTests("MIDI send failed; test output locked.")
                    return .failed
                }
            }
            if hardwareMode, authorizedTest == nil, messages.contains(where: {
                if case .programChange = $0 {
                    return true
                }; return false
            }) {
                hardwareFeedbackNeedsSync = false
                if error as? CompactError == .fadersTouched {
                    error = nil
                }
            }
            return .sent
        }

        func applyAgentParameter(_ id: String, value: Double) throws {
            try sendAgentFeedback(session.setParameter(id, value: value, fromAgent: true, drivesMotors: mcpMotorWritesAllowed))
        }

        func notificationsForOSC(_ key: String) {
            notifications.removeAll { $0.id == "osc" }
            notifications.append(ConsoleNotification(id: "osc", level: .warning, message: LocalizedMessage(key), persistent: false))
        }

        func serviceError(_ failure: any Error) {
            error = failure; mcpEnabled = mcp.isRunning
        }

        func sendAgentFeedback(_ messages: [MIDIMessage]) {
            agentOutput = true; send(messages); agentOutput = false; updateBank()
        }

        func logAgentCall(_ name: String) {
            appendEvent(MonitorEvent(timestamp: now(), direction: nil, source: .agent, message: nil, control: nil,
                                     hostLayer: layer, ignored: false, text: LocalizedMessage("Agent call: %@", name)))
        }

        // MARK: - Organization: naming, color tags, groups, links, scenes, undo

        // Metadata edits never move a motor. Scene recall changes host intent only.

        /// Parameter bound to a control on the current layer, if any.
        func boundParameter(_ control: CompactControl) -> String? {
            guard case let .parameter(id) = session.parameters.assignment(control, layer: layer) else { return nil }
            return id
        }

        /// Rename the control's parameter. An unbound fader or encoder gets a new continuous
        /// parameter on the current layer, initialized from the control's current bank value.
        func renameControl(_ control: CompactControl, name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            var configuration = session.parameters.configuration
            if let id = boundParameter(control),
               let index = configuration.parameters.firstIndex(where: { $0.id == id })
            {
                configuration.parameters[index].name = trimmed
                commitMetadata(configuration)
                return
            }
            let raw: UInt8
            switch control {
            case let .fader(index): raw = bank.faders[index - 1]
            case let .encoder(index): raw = bank.encoders[index - 1]
            default: return // Buttons and pushes carry actions, not a single continuous value.
            }
            let id = "\(layer.rawValue).\(control.shortName).\(UUID().uuidString.prefix(8))"
            configuration.parameters.append(XTouchCompactCore.ParameterDefinition(id: id, name: trimmed, group: "Layer \(layer.rawValue.uppercased())",
                                                                                  defaultValue: Double(raw)))
            configuration.assignments.removeAll { $0.control == control && $0.layer == layer }
            configuration.assignments.append(ControlAssignment(control: control, layer: layer, action: .parameter(id)))
            commitMetadata(configuration)
            // The new parameter starts at the bank value already shown: no visible jump, no motor.
            do { _ = try session.restoreParameterValues([id: Double(raw)]) } catch { self.error = error }
            refreshAfterMetadata()
        }

        func setControlColor(_ control: CompactControl, color: ParameterColor?) {
            editBoundDefinition(control) { $0.color = color }
        }

        func setControlGroup(_ control: CompactControl, group: String) {
            let trimmed = group.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            editBoundDefinition(control) { $0.group = trimmed }
        }

        func saveLink(_ link: ParameterLink) {
            var configuration = session.parameters.configuration
            var links = configuration.links ?? []
            if let index = links.firstIndex(where: { $0.id == link.id }) {
                links[index] = link
            } else {
                links.append(link)
            }
            configuration.links = links
            commitMetadata(configuration)
        }

        func deleteLink(_ id: String) {
            var configuration = session.parameters.configuration
            configuration.links = (configuration.links ?? []).filter { $0.id != id }
            commitMetadata(configuration)
        }

        func captureScene(name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            let existing = session.parameters.configuration.scenes?.first { $0.name == trimmed }
            do {
                try session.captureScene(id: existing?.id ?? UUID().uuidString, name: trimmed)
                saveWorkspace()
            } catch { self.error = error }
        }

        /// Rename a scene without touching its stored values. Blank or duplicate names are ignored
        /// so that "save under an existing name updates it" stays unambiguous.
        func renameScene(_ id: String, name: String) {
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            var configuration = session.parameters.configuration
            guard !trimmed.isEmpty, var scenes = configuration.scenes,
                  let index = scenes.firstIndex(where: { $0.id == id }),
                  !scenes.contains(where: { $0.id != id && $0.name == trimmed }) else { return }
            scenes[index].name = trimmed
            configuration.scenes = scenes
            commitMetadata(configuration)
        }

        func recallScene(_ id: String) {
            apply { try $0.recallScene(id: id) }
            log(LocalizedMessage("Scene recalled; faders move only with the explicit motor recall."))
        }

        func deleteScene(_ id: String) {
            do { try session.deleteScene(id: id); saveWorkspace() } catch { self.error = error }
        }

        func undo() {
            apply { try $0.undo() }
        }

        func redo() {
            apply { try $0.redo() }
        }

        private func editBoundDefinition(_ control: CompactControl, _ change: (inout XTouchCompactCore.ParameterDefinition) -> Void) {
            guard let id = boundParameter(control) else { return }
            var configuration = session.parameters.configuration
            guard let index = configuration.parameters.firstIndex(where: { $0.id == id }) else { return }
            change(&configuration.parameters[index])
            commitMetadata(configuration)
        }

        /// Validate and apply a metadata-only edit, then persist it. Values and motors stay put.
        private func commitMetadata(_ configuration: SurfaceConfiguration) {
            do {
                try configuration.validate()
                try session.replaceConfigurationKeepingValues(configuration)
                refreshAfterMetadata()
                saveWorkspace()
            } catch { self.error = error }
        }

        private func refreshAfterMetadata() {
            objectWillChange.send()
        }

        private enum ConsoleError: Error { case noConnection }

        func errorText(using l: Localizer) -> String {
            guard let error else { return connection.error.map { l.text($0) } ?? "" }
            return l.text(localizedError(error))
        }

        func localizedError(_ error: any Error) -> LocalizedMessage {
            let l = ErrorMessageBuilder()
            switch error {
            case let failure as NonMotorTestError:
                switch failure {
                case .prerequisitesMissing: return l.text("Complete the operator prerequisites before enabling test output.")
                case .recordingRequired: return l.text("Active recording is required for nonmotor tests.")
                case .connectionMissing, .connectionChanged: return l.text("MIDI route changed; test output locked.")
                case .permissionRevoked: return l.text("Test output locked.")
                case .invalidTransmission: return l.text("Only the exact approved nonmotor command can be sent.")
                case .observationUnavailable: return l.text("Record observations only for the latest delivered command on this route.")
                case .previewRequired: return l.text("Select a test RX channel and preview this command before sending.")
                }
            case let failure as EvidenceError:
                switch failure {
                case .fileExists: return l.text("Evidence already exists. Choose a new filename.")
                case .closed: return l.text("Evidence writer is closed.")
                }
            case is CaptureReviewError:
                return l.text("Capture evidence is malformed; the original was preserved.")
            case is ConsoleError:
                return l.text("No complete Compact MIDI input/output connection; select endpoints or connect hardware.")
            case let error as CompactMIDIError:
                switch error {
                case let .operation(operation, status): return l.text("%@ (OSStatus %@)", operation, String(status), localizedArgumentIndices: [0])
                case .outputUnavailable: return l.text("X-TOUCH COMPACT MIDI output not connected")
                case .packetOverflow: return l.text("MIDI packet could not be built")
                case .routeChanged: return l.text("MIDI route changed; test output locked.")
                }
            case let failure as ParameterError:
                switch failure {
                case .wrongDeviceOrVersion: return l.text("Only X-TOUCH COMPACT version 1 or 2 configurations are supported; protection fields require version 2.")
                case .duplicateParameter: return l.text("Parameter IDs must be unique.")
                case let .invalidDefinition(id): return l.text("Invalid parameter range or step: %@", id)
                case .invalidAssignment: return l.text("Invalid control assignment. Check control numbers and Agent slots.")
                case let .unknownParameter(id): return l.text("Unknown parameter: %@", id)
                case let .agentDenied(id): return l.text("Agent write denied: %@", id)
                case let .invalidLink(id): return l.text("Invalid fader link: %@. Leader and members must exist, differ, and not chain.", id)
                case let .invalidScene(id): return l.text("Invalid scene: %@. A scene needs a name.", id)
                }
            case let failure as StoreError:
                switch failure {
                case let .protectedCorruptFile(url): return l.text("Invalid workspace preserved; repair the original before saving. Backup: %@", url.path)
                case .symbolicLink: return l.text("Workspace storage refuses symbolic links.")
                }
            case let error as CompactError:
                switch error {
                case .fadersTouched: return l.text("Layer change refused while a fader is touched. Release all faders and retry; nothing was queued.")
                case let .invalidChannel(channel): return l.text("Invalid MIDI channel: %@", String(channel))
                case let .invalidIndex(control, index): return l.text("Invalid %@ index: %@", control, String(index), localizedArgumentIndices: [0])
                case let .invalidMIDIValue(value): return l.text("Invalid MIDI value: %@", String(value))
                case let .invalidDisplayPosition(position): return l.text("Invalid ring position: %@", String(position))
                }
            default: return l.text("Error: %@", error.localizedDescription)
            }
        }

        func chooseImportConfiguration() {
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false
            if panel.runModal() == .OK, let url = panel.url {
                importConfiguration(url)
            }
        }

        func chooseExportConfiguration() {
            let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "XTouchCompact.json"
            if panel.runModal() == .OK, let url = panel.url {
                exportConfiguration(url)
            }
        }

        func importConfiguration(_ url: URL) {
            do {
                let data = try Data(contentsOf: url)
                guard let header = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      header["device"] as? String == "X-TOUCH COMPACT", [1, 2].contains(header["version"] as? Int)
                else {
                    throw ParameterError.wrongDeviceOrVersion
                }
                let configuration = try JSONDecoder().decode(SurfaceConfiguration.self, from: data)
                try configuration.validate()
                loadPreset(configuration)
            } catch { self.error = error }
        }

        func exportConfiguration(_ url: URL) {
            do { try JSONEncoder().encode(session.parameters.configuration).write(to: url, options: .atomic) }
            catch { self.error = error }
        }

        private func storageFailure(_ failure: any Error) {
            notifications.removeAll { $0.id == "storage" }
            notifications.append(ConsoleNotification(id: "storage", level: .error, message: localizedError(failure), persistent: true))
        }

        func retryWorkspaceSave() {
            saveWorkspace()
        }

        func saveWorkspace() {
            guard let store else { return }
            var profile = DeviceProfile()
            profile.transmitChannel = Int(session.state.map.transmitChannel) + 1
            profile.receiveChannel = Int(session.state.map.globalReceiveChannel) + 1
            profile.ledProtocol = session.state.lightProtocol
            profile.inputID = appliedInputID
            profile.outputID = appliedOutputID
            do {
                var workspace = SavedWorkspace(configuration: session.parameters.configuration, profile: profile)
                workspace.hardwareValues = hardwareValueCache
                workspace.parameterValues = session.parameters.values
                try store.save(workspace)
                savedParameterValues = workspace.parameterValues
                hardwareValuesDirty = false
                hardwareValuesSavedAt = runtimeTime
                notifications.removeAll { $0.id == "storage" }
            } catch { storageFailure(error) }
        }

        var parameterValuesDirty: Bool {
            store != nil && savedParameterValues != session.parameters.values
        }

        /// Flush pending hardware readings and parameter values (runtime tick and app termination).
        func flushHardwareValues() {
            guard hardwareValuesDirty || parameterValuesDirty, store != nil else { return }
            // Limit retries too; a failed save remains visible and never overwrites corrupt data.
            hardwareValuesSavedAt = runtimeTime
            saveWorkspace()
        }

        func clearMonitor() {
            events.removeAll()
        }

        func dismissNotification(_ id: String) {
            guard notifications.first(where: { $0.id == id })?.persistent != true else { return }
            if id == "runtime" {
                error = nil
            }
            notifications.removeAll { $0.id == id }
        }

        private func record(_ message: MIDIMessage, direction: MonitorEvent.Direction,
                            source: MonitorEvent.Source, ignored: Bool = false, delivery: MonitorEvent.Delivery? = nil,
                            nonMotorTest: NonMotorTestAudit? = nil, controlOverride: CompactControl? = nil)
        {
            let control: CompactControl?
            if let controlOverride {
                control = controlOverride
            } else if direction == .input {
                control = session.state.map.decode(message)?.control
            } else {
                let candidates = (1 ... 9).map(CompactControl.fader) + (1 ... 16).map(CompactControl.encoder)
                    + (1 ... 39).map(CompactControl.button)
                control = candidates.first { control in
                    let address = session.state.map.feedbackAddress(for: control)
                    switch message {
                    case let .controlChange(c, n, _):
                        if address?.messageType == .controlChange, address?.channel == c, address?.number == n {
                            return true
                        }
                        if case let .encoder(index) = control, let style = session.state.map.encoderRingStyleAddress(encoder: index) {
                            return style.channel == c && style.number == n
                        }
                        return false
                    case let .noteOn(c, n, _): return address?.messageType == .note && address?.channel == c && address?.number == n
                    default: return false
                    }
                }
            }
            let key = direction == .input ? (source == .mock ? "IN %@ [MOCK]" : "IN %@")
                : (!hardwareMode ? "OUT %@ [MOCK]" : "OUT %@")
            appendEvent(MonitorEvent(timestamp: now(), direction: direction, source: source, message: message,
                                     control: control, hostLayer: session.state.layer,
                                     deviceLayer: direction == .input ? session.state.map.decode(message)?.layer : nil,
                                     delivery: delivery ?? (direction == .input ? .received : nil),
                                     ignored: ignored, text: LocalizedMessage(key, message.description), nonMotorTest: nonMotorTest))
        }

        private func appendEvent(_ event: MonitorEvent) {
            events.insert(event, at: 0); trimEvents()
            do {
                try monitorCapture?.append(event, map: session.state.map,
                                           lightProtocol: session.state.lightProtocol,
                                           hardwareMode: hardwareMode, listenOnly: listenOnly)
            } catch {
                captureFailed(error)
            }
        }

        func chooseStartCapture() {
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "XTouchCompact-capture-\(Int(now().timeIntervalSince1970)).jsonl"
            if panel.runModal() == .OK, let url = panel.url {
                startCapture(url)
            }
        }

        func startCapture(_ url: URL) {
            guard monitorCapture == nil else { return }
            do {
                monitorCapture = try MonitorCapture(url: url, started: now(), metadata: captureMetadata(), writerFactory: evidenceWriterFactory)
                capturePath = url.path
                lastCaptureURL = url
                error = nil
            } catch { self.error = error }
        }

        func captureMetadata() -> CaptureSessionMetadata {
            let info = Bundle.main.infoDictionary ?? [:]
            return CaptureSessionMetadata(
                applicationVersion: info["CFBundleShortVersionString"] as? String,
                sourceRevision: info["XTouchSourceRevision"] as? String,
                sourceTreeDirty: info["XTouchSourceTreeDirty"] as? Bool,
                connectedInput: connection.connectedInput, connectedOutput: connection.connectedOutput,
                selectedInputID: appliedInputID, selectedOutputID: appliedOutputID,
                configuredTX: Int(session.state.map.transmitChannel) + 1,
                configuredGlobalRX: Int(session.state.map.globalReceiveChannel) + 1,
                ledProtocol: session.state.lightProtocol.rawValue, hardwareMode: hardwareMode, listenOnly: listenOnly,
                connectionGeneration: connection.connectedInput == nil ? nil : connection.generation
            )
        }

        func stopCapture() {
            lockNonMotorTests("Recording stopped; test output locked.")
            defer { monitorCapture = nil; capturePath = nil }
            do { try monitorCapture?.finish(at: now()) }
            catch { self.error = error }
        }

        func chooseExportInputReview() {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.directoryURL = lastCaptureURL?.deletingLastPathComponent()
            panel.nameFieldStringValue = "XTouchCompact-input-review-\(Int(now().timeIntervalSince1970)).json"
            if panel.runModal() == .OK, let url = panel.url {
                exportInputReview(url)
            }
        }

        func exportInputReview(_ url: URL) {
            lastReviewExport = nil
            do {
                lastReviewExport = try InputReviewExporter.export(to: url, observer: hardwareObserver,
                                                                  observationStarted: observationStartedAt, captureURL: lastCaptureURL,
                                                                  metadata: captureMetadata(), at: now(), nonMotorAttempts: nonMotorTests.attempts)
                error = nil
            } catch { self.error = error }
        }

        private func trimEvents() {
            if events.count > 120 {
                events.removeLast(events.count - 120)
            }
        }

        private func updateBank() {
            if !session.state.layerMismatch, notifications.contains(where: { $0.id == "layer" }) {
                notifications.removeAll { $0.id == "layer" }
            }
            let next = session.bank(layer)
            if bank != next {
                bank = next
            }
        }

        func log(_ entry: LocalizedMessage) {
            appendEvent(MonitorEvent(timestamp: now(), direction: nil, source: .application, message: nil,
                                     control: nil, hostLayer: layer, ignored: false, text: entry))
        }
    }
#endif
