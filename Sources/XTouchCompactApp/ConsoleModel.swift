#if os(macOS)
import Foundation
import SwiftUI
import XTouchCompactCore
import XTouchCompactLocalization

/// SwiftUI state is deliberately separate from the value-only/testable protocol session.
@MainActor
final class ConsoleModel: ObservableObject {
    @Published private(set) var bank = CompactParameterBank()
    @Published private(set) var layer: CompactLayer = .a
    @Published private(set) var connection = CompactMIDIConnection()
    @Published private(set) var events: [MonitorEvent] = []
    var logs: [LocalizedMessage] { events.map(\.text) }
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
            if error != nil { notifications.append(ConsoleNotification(id: "runtime", level: .error, persistent: false)) }
        }
    }

    private let midi: any MIDIService
    private let now: () -> Date
    private(set) var session: CompactSession
    private(set) var mock: MockXTouchCompact

    init(startsMIDI: Bool = true, midi: (any MIDIService)? = nil, now: @escaping () -> Date = Date.init) {
        self.midi = midi ?? CoreMIDIService()
        self.now = now
        let map = try! FactoryStandardMap() // Constant channels are valid by construction.
        session = CompactSession(map: map, lightProtocol: .manual)
        mock = MockXTouchCompact(map: map, lightProtocol: .manual)
        self.midi.onMessages = { [weak self] messages in self?.receive(messages) }
        self.midi.onConnection = { [weak self] snapshot in
            guard let self else { return }
            let wasConnected = self.connection.isConnected
            self.connection = snapshot
            if self.hardwareMode && snapshot.isConnected && !wasConnected {
                self.apply { try $0.connect() }
            }
            if self.hardwareMode && !snapshot.isConnected { self.session.invalidateTransportFeedback() }
        }
        if startsMIDI {
            do { try self.midi.start() } catch { self.error = error }
        }
        apply { try $0.connect() }
    }

    func useHardware(_ enabled: Bool) {
        hardwareMode = enabled
        if enabled {
            guard connection.isConnected else {
                error = ConsoleError.noConnection
                return
            }
            apply { try $0.connect() }
        } else {
            error = nil
            apply { try $0.connect() }
            // A mock hand can still be holding a physical fader across a mode switch.
            for index in mock.touchedFaders.sorted() { touchFader(index, isTouched: true) }
            log(LocalizedMessage("Switched to deterministic mock surface"))
        }
    }

    func configure() {
        do {
            guard (1...16).contains(transmitChannel), (1...16).contains(feedbackChannel) else {
                throw CompactError.invalidChannel(16)
            }
            let map = try FactoryStandardMap(
                transmitChannel: UInt8(transmitChannel - 1),
                globalReceiveChannel: UInt8(feedbackChannel - 1)
            )
            guard (1...16).contains(transmitChannel), (1...16).contains(feedbackChannel) else {
                throw CompactError.invalidChannel(16)
            }
            let variant: ButtonLightProtocol = observedLEDVariant ? .observed114 : .manual
            mock = MockXTouchCompact(map: map, lightProtocol: variant)
            for index in 1...9 where session.state.isTouched(index) {
                _ = try mock.touchFader(index, isTouched: true)
            }
            apply { try $0.reconfigure(map: map, lightProtocol: variant) }
            log(LocalizedMessage("Profile applied; parameter values preserved"))
        } catch { self.error = error }
    }

    func selectPorts() {
        midi.select(inputID: inputChoice == 0 ? nil : inputChoice,
                    outputID: outputChoice == 0 ? nil : outputChoice)
    }

    func setLayer(_ next: CompactLayer) {
        apply { try $0.selectLayer(next) }
        layer = next
        updateBank()
    }

    func recallMotors() { apply { try $0.recallFaders() } }

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
        if hardwareMode { faderChanged(index, value: Double(value)) }
        else { performMockGesture { try $0.moveFader(index, value: value) } }
    }

    func touchFader(_ index: Int, isTouched: Bool) {
        performMockGesture { try $0.touchFader(index, isTouched: isTouched) }
    }

    func turnEncoder(_ index: Int, delta: Int) {
        if hardwareMode {
            guard (1...CompactGeometry.encoderCount).contains(index) else { return }
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
        do { receive(try operation(&mock), fromMock: true) }
        catch { self.error = error }
    }

    private func receive(_ messages: [MIDIMessage], fromMock: Bool = false) {
        for message in messages {
            record(message, direction: .input, source: fromMock ? .mock : .hardware,
                   ignored: hardwareMode == fromMock || session.state.map.decode(message, layer: layer) == nil)
        }
        guard hardwareMode != fromMock else { return }
        do {
            let update = try session.receive(messages)
            send(update.feedback)
            if !update.inputs.isEmpty { updateBank() }
        } catch { self.error = error }
    }

    private func apply(_ operation: (inout CompactSession) throws -> [MIDIMessage]) {
        do {
            send(try operation(&session))
            updateBank()
        }
        catch { self.error = error }
    }

    private func send(_ messages: [MIDIMessage]) {
        for message in messages {
            record(message, direction: .output, source: hardwareMode ? .hardware : .mock)
            guard hardwareMode else {
                mock.receive(message)
                continue
            }
            do { try midi.send(message) }
            catch {
                self.error = error
                session.invalidateTransportFeedback()
                break
            }
        }
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

    func clearMonitor() { events.removeAll() }
    func dismissNotification(_ id: String) {
        guard notifications.first(where: { $0.id == id })?.persistent != true else { return }
        if id == "runtime" { error = nil }
        notifications.removeAll { $0.id == id }
    }

    private func record(_ message: MIDIMessage, direction: MonitorEvent.Direction,
                        source: MonitorEvent.Source, ignored: Bool = false) {
        let control: CompactControl?
        if direction == .input { control = session.state.map.decode(message, layer: layer)?.control }
        else {
            let candidates = (1...9).map(CompactControl.fader) + (1...16).map(CompactControl.encoder)
                + (1...39).map(CompactControl.button)
            control = candidates.first { control in
                let address = session.state.map.feedbackAddress(for: control)
                switch message {
                case let .controlChange(c, n, _): return address?.messageType == .controlChange && address?.channel == c && address?.number == n
                case let .noteOn(c, n, _): return address?.messageType == .note && address?.channel == c && address?.number == n
                default: return false
                }
            }
        }
        let key = direction == .input ? (source == .mock ? "IN %@ [MOCK]" : "IN %@")
                                     : (source == .mock ? "OUT %@ [MOCK]" : "OUT %@")
        events.insert(MonitorEvent(timestamp: now(), direction: direction, source: source, message: message,
                                   control: control, ignored: ignored, text: LocalizedMessage(key, message.description)), at: 0)
        trimEvents()
    }

    private func trimEvents() {
        if events.count > 120 { events.removeLast(events.count - 120) }
    }

    private func updateBank() { bank = session.bank(layer) }
    private func log(_ entry: LocalizedMessage) {
        events.insert(MonitorEvent(timestamp: now(), direction: nil, source: .application, message: nil,
                                   control: nil, ignored: false, text: entry), at: 0)
        trimEvents()
    }
}
#endif
