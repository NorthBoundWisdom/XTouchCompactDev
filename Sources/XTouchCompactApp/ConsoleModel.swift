#if os(macOS)
    import AppKit
    import Foundation
    import Network
    import SwiftUI
    import UniformTypeIdentifiers
    import XTouchCompactCore
    import XTouchCompactLocalization

    /// SwiftUI state is deliberately separate from the value-only/testable protocol session.
    @MainActor
    final class ConsoleModel: ObservableObject {
        @Published private(set) var bank = CompactParameterBank()
        @Published private(set) var layer: CompactLayer = .a
        @Published private(set) var connection = CompactMIDIConnection()
        @Published private(set) var events: [MonitorEvent] = []
        var logs: [LocalizedMessage] {
            events.map(\.text)
        }

        @Published private(set) var notifications: [ConsoleNotification] = []
        @Published private(set) var hardwareMode = false
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

        @Published private(set) var agents = MockAgents()

        let mcp = LocalMCPServer()
        let isolated: Bool
        private let memoryToken = UUID().uuidString + UUID().uuidString
        func accessToken() throws -> String {
            isolated ? memoryToken : try MCPTokenStore().token()
        }

        @Published var mcpEnabled = false
        @Published var mcpWritesAllowed = false
        @Published var oscHost = "127.0.0.1"
        @Published var oscPort: UInt16 = 9000
        @Published var oscParameter = "a.Fader.1"
        @Published var oscEnabled = false
        @Published var oscOutput = 0.0
        var oscGate = try! MotionSafetyGate()
        var oscConnection: NWConnection?
        private var agentOutput = false

        private let midi: any MIDIService
        private var appliedInputID: Int32?
        private var appliedOutputID: Int32?
        private let store: ProtectedWorkspaceStore?
        private let now: () -> Date
        private(set) var session: CompactSession
        private(set) var mock: MockXTouchCompact

        init(startsMIDI: Bool = true, midi: (any MIDIService)? = nil, now: @escaping () -> Date = Date.init, storageRoot: URL? = nil, isolated: Bool = false) {
            self.midi = midi ?? CoreMIDIService()
            self.now = now
            self.isolated = isolated
            store = storageRoot.map(ProtectedWorkspaceStore.init(directory:))
            let map = try! FactoryStandardMap() // Constant channels are valid by construction.
            session = CompactSession(map: map, lightProtocol: .manual)
            mock = MockXTouchCompact(map: map, lightProtocol: .manual)
            self.midi.onMessages = { [weak self] messages in self?.receive(messages) }
            self.midi.onConnection = { [weak self] snapshot in
                guard let self else { return }
                let wasConnected = connection.isConnected
                connection = snapshot
                if hardwareMode, snapshot.isConnected, !wasConnected {
                    apply { try $0.connect() }
                }
                if hardwareMode, !snapshot.isConnected {
                    session.invalidateTransportFeedback()
                }
            }
            if let store {
                do {
                    if let saved = try store.load() {
                        transmitChannel = saved.profile.transmitChannel
                        feedbackChannel = saved.profile.receiveChannel
                        observedLEDVariant = saved.profile.ledProtocol == .observed114
                        inputChoice = saved.profile.inputID ?? 0
                        outputChoice = saved.profile.outputID ?? 0
                        appliedInputID = saved.profile.inputID
                        appliedOutputID = saved.profile.outputID
                        let map = try FactoryStandardMap(transmitChannel: UInt8(transmitChannel - 1), globalReceiveChannel: UInt8(feedbackChannel - 1))
                        _ = try session.reconfigure(map: map, lightProtocol: saved.profile.ledProtocol)
                        _ = try session.loadConfiguration(saved.configuration)
                        mock = MockXTouchCompact(map: map, lightProtocol: saved.profile.ledProtocol)
                    }
                } catch { storageFailure(error) }
            }
            if startsMIDI {
                do { try self.midi.start() } catch { self.error = error }
            }
            self.midi.select(inputID: inputChoice == 0 ? nil : inputChoice, outputID: outputChoice == 0 ? nil : outputChoice)
            apply { try $0.connect() }
        }

        func useHardware(_ enabled: Bool) {
            guard hardwareMode != enabled else { return }
            session.prepareTransportSwitch(inputTouches: enabled ? [] : mock.touchedFaders)
            if notifications.contains(where: { $0.id == "layer" }) {
                notifications.removeAll { $0.id == "layer" }
            }
            hardwareMode = enabled
            if enabled {
                guard connection.isConnected else {
                    error = ConsoleError.noConnection
                    return
                }
                session.setInputTouches([])
                apply { try $0.selectLayer(layer) }
            } else {
                error = nil
                session.setInputTouches(mock.touchedFaders)
                apply { try $0.selectLayer(layer) }
                log(LocalizedMessage("Switched to deterministic mock surface"))
            }
        }

        func configure() {
            do {
                guard (1 ... 16).contains(transmitChannel), (1 ... 16).contains(feedbackChannel) else {
                    throw CompactError.invalidChannel(16)
                }
                let map = try FactoryStandardMap(
                    transmitChannel: UInt8(transmitChannel - 1),
                    globalReceiveChannel: UInt8(feedbackChannel - 1)
                )

                let variant: ButtonLightProtocol = observedLEDVariant ? .observed114 : .manual
                mock = mock.reconfigured(map: map, lightProtocol: variant)
                apply { try $0.reconfigure(map: map, lightProtocol: variant) }
                log(LocalizedMessage("Profile applied; parameter values preserved"))
                saveWorkspace()
            } catch { self.error = error }
        }

        func agentPrimary(_ slot: Int, fromAgent: Bool = false) {
            agentOutput = fromAgent
            defer { agentOutput = false }
            agents.primary(slot, now: now().timeIntervalSince1970)
            apply { try $0.agentFeedback(agents) }
        }

        func advanceAgents() {
            tickOSC()
            agents.advance(to: now().timeIntervalSince1970)
            apply { try $0.agentFeedback(agents) }
        }

        func setParameter(_ id: String, value: Double, fromAgent: Bool = false) {
            apply { try $0.setParameter(id, value: value, fromAgent: fromAgent) }
        }

        func loadConfiguration(_ configuration: SurfaceConfiguration) {
            do {
                let messages = try session.loadConfiguration(configuration)
                send(messages); updateBank(); saveWorkspace()
            } catch { self.error = error }
        }

        func selectPorts() {
            appliedInputID = inputChoice == 0 ? nil : inputChoice
            appliedOutputID = outputChoice == 0 ? nil : outputChoice
            midi.select(inputID: inputChoice == 0 ? nil : inputChoice,
                        outputID: outputChoice == 0 ? nil : outputChoice)
            saveWorkspace()
        }

        func setLayer(_ next: CompactLayer) {
            apply { try $0.selectLayer(next) }
            layer = next
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
            apply { try $0.toggleButton(index) }
            updateBank()
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

        func releaseButton(_ index: Int) {
            performMockGesture { try $0.pressButton(index, isDown: false) }
        }

        private func performMockGesture(_ operation: (inout MockXTouchCompact) throws -> [MIDIMessage]) {
            guard !hardwareMode else { return }
            do { try receive(operation(&mock), fromMock: true) }
            catch { self.error = error }
        }

        private func receive(_ messages: [MIDIMessage], fromMock: Bool = false) {
            for message in messages {
                let event = session.state.map.decode(message)
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
                for slot in update.agentIntents {
                    agentPrimary(slot)
                }
                if !update.inputs.isEmpty {
                    updateBank()
                }
            } catch { self.error = error }
        }

        private func apply(_ operation: (inout CompactSession) throws -> [MIDIMessage]) {
            do {
                try send(operation(&session))
                updateBank()
            } catch { self.error = error }
        }

        private func send(_ messages: [MIDIMessage]) {
            for message in messages {
                record(message, direction: .output, source: agentOutput ? .agent : (hardwareMode ? .hardware : .mock))
                guard hardwareMode else {
                    mock.receive(message)
                    continue
                }
                do { try midi.send(message) }
                catch {
                    self.error = error
                    if !events.isEmpty {
                        events[0].ignored = true
                    }
                    session.invalidateTransportFeedback()
                    break
                }
            }
        }

        func applyAgentParameter(_ id: String, value: Double) throws {
            try sendAgentFeedback(session.setParameter(id, value: value, fromAgent: true))
        }

        func serviceError(_ failure: any Error) {
            error = failure; mcpEnabled = mcp.isRunning
        }

        func sendAgentFeedback(_ messages: [MIDIMessage]) {
            agentOutput = true; send(messages); agentOutput = false; updateBank()
        }

        func logAgentCall(_ name: String) {
            events.insert(MonitorEvent(timestamp: now(), direction: nil, source: .agent, message: nil, control: nil,
                                       ignored: false, text: LocalizedMessage("Agent call: %@", name)), at: 0)
            trimEvents()
        }

        func realignCurrentLayer() {
            setLayer(layer)
        }

        private enum ConsoleError: Error { case noConnection }

        func errorText(using l: Localizer) -> String {
            guard let error else { return connection.error.map { l.text($0) } ?? "" }
            switch error {
            case is ConsoleError:
                return l.text("No complete Compact MIDI input/output connection; select endpoints or connect hardware.")
            case let error as CompactMIDIError:
                switch error {
                case let .operation(operation, status): return l.text("%@ (OSStatus %@)", l.text(operation), String(status))
                case .outputUnavailable: return l.text("X-TOUCH COMPACT MIDI output not connected")
                case .packetOverflow: return l.text("MIDI packet could not be built")
                }
            case let failure as ParameterError:
                switch failure {
                case .wrongDeviceOrVersion: return l.text("Only X-TOUCH COMPACT version 1 configurations are supported.")
                case .duplicateParameter: return l.text("Parameter IDs must be unique.")
                case let .invalidDefinition(id): return l.text("Invalid parameter range or step: %@", id)
                case .invalidAssignment: return l.text("Invalid control assignment. Check control numbers and Agent slots.")
                case let .unknownParameter(id): return l.text("Unknown parameter: %@", id)
                case let .agentDenied(id): return l.text("Agent write denied: %@", id)
                }
            case let failure as StoreError:
                switch failure {
                case let .protectedCorruptFile(url): return l.text("Invalid workspace preserved; repair the original before saving. Backup: %@", url.path)
                case .symbolicLink: return l.text("Workspace storage refuses symbolic links.")
                }
            case let error as CompactError:
                switch error {
                case let .invalidChannel(channel): return l.text("Invalid MIDI channel: %@", String(channel))
                case let .invalidIndex(control, index): return l.text("Invalid %@ index: %@", l.text(control), String(index))
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
                let configuration = try JSONDecoder().decode(SurfaceConfiguration.self, from: data)
                try configuration.validate()
                loadConfiguration(configuration)
            } catch { self.error = error }
        }

        func exportConfiguration(_ url: URL) {
            do { try JSONEncoder().encode(session.parameters.configuration).write(to: url, options: .atomic) }
            catch { self.error = error }
        }

        private func storageFailure(_ failure: any Error) {
            notifications.removeAll { $0.id == "storage" }
            notifications.append(ConsoleNotification(id: "storage", level: .error, message: LocalizedMessage("Storage error: %@", failure.localizedDescription), persistent: true))
        }

        func retryWorkspaceSave() {
            saveWorkspace()
        }

        private func saveWorkspace() {
            guard let store else { return }
            var profile = DeviceProfile()
            profile.transmitChannel = Int(session.state.map.transmitChannel) + 1
            profile.receiveChannel = Int(session.state.map.globalReceiveChannel) + 1
            profile.ledProtocol = session.state.lightProtocol
            profile.inputID = appliedInputID
            profile.outputID = appliedOutputID
            do {
                try store.save(SavedWorkspace(configuration: session.parameters.configuration, profile: profile))
                notifications.removeAll { $0.id == "storage" }
            } catch { storageFailure(error) }
        }

        func clearMonitor() {
            events.removeAll()
        }

        func dismissNotification(_ id: String) {
            guard notifications.first(where: { $0.id == id })?.persistent != true else { return }
            if id == "runtime" {
                guard !notifications.contains(where: { $0.id == "storage" }) else { return }
                error = nil
            }
            notifications.removeAll { $0.id == id }
        }

        private func record(_ message: MIDIMessage, direction: MonitorEvent.Direction,
                            source: MonitorEvent.Source, ignored: Bool = false)
        {
            let control: CompactControl?
            if direction == .input {
                control = session.state.map.decode(message, layer: layer)?.control
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
            events.insert(MonitorEvent(timestamp: now(), direction: direction, source: source, message: message,
                                       control: control, ignored: ignored, text: LocalizedMessage(key, message.description)), at: 0)
            trimEvents()
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

        private func log(_ entry: LocalizedMessage) {
            events.insert(MonitorEvent(timestamp: now(), direction: nil, source: .application, message: nil,
                                       control: nil, ignored: false, text: entry), at: 0)
            trimEvents()
        }
    }
#endif
