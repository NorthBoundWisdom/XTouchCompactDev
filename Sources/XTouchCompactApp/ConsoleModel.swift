#if os(macOS)
import Foundation
import SwiftUI
import XTouchCompactCore

/// SwiftUI state is deliberately separate from the value-only/testable protocol session.
@MainActor
final class ConsoleModel: ObservableObject {
    @Published private(set) var bank = CompactParameterBank()
    @Published private(set) var layer: CompactLayer = .a
    @Published private(set) var connection = CompactMIDIConnection()
    @Published private(set) var logs: [String] = []
    @Published private(set) var hardwareMode = false
    @Published var transmitChannel = 1
    @Published var feedbackChannel = 1
    @Published var inputChoice: Int32 = 0
    @Published var outputChoice: Int32 = 0
    @Published var observedLEDVariant = false
    @Published private(set) var error: String?

    private let midi = CoreMIDIService()
    private(set) var session: CompactSession
    private(set) var mock: MockXTouchCompact

    init(startsMIDI: Bool = true) {
        let map = try! FactoryStandardMap() // Constant channels are valid by construction.
        session = CompactSession(map: map, lightProtocol: .manual)
        mock = MockXTouchCompact(map: map, lightProtocol: .manual)
        midi.onMessages = { [weak self] messages in self?.receive(messages) }
        midi.onConnection = { [weak self] snapshot in
            guard let self else { return }
            let wasConnected = self.connection.isConnected
            self.connection = snapshot
            if self.hardwareMode && snapshot.isConnected && !wasConnected {
                self.apply { try $0.connect() }
            }
            if self.hardwareMode && !snapshot.isConnected { self.session.invalidateTransportFeedback() }
        }
        if startsMIDI {
            do { try midi.start() } catch { self.error = error.localizedDescription }
        }
        apply { try $0.connect() }
    }

    func useHardware(_ enabled: Bool) {
        hardwareMode = enabled
        if enabled {
            guard connection.isConnected else {
                error = "No complete Compact MIDI input/output connection; select endpoints or connect hardware."
                return
            }
            apply { try $0.connect() }
        } else {
            error = nil
            apply { try $0.connect() }
            // A mock hand can still be holding a physical fader across a mode switch.
            for index in mock.touchedFaders.sorted() { touchFader(index, isTouched: true) }
            log("Switched to deterministic mock surface")
        }
    }

    func configure() {
        do {
            let map = try FactoryStandardMap(
                transmitChannel: UInt8(transmitChannel - 1),
                globalReceiveChannel: UInt8(feedbackChannel - 1)
            )
            session = CompactSession(map: map,
                lightProtocol: observedLEDVariant ? .observed114 : .manual)
            mock = MockXTouchCompact(map: map,
                lightProtocol: observedLEDVariant ? .observed114 : .manual)
            layer = .a
            updateBank()
            log("MIDI channel/profile changed; application values reset")
            if hardwareMode && connection.isConnected { apply { try $0.connect() } }
            if !hardwareMode { apply { try $0.connect() } }
        } catch { self.error = error.localizedDescription }
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
        catch { self.error = error.localizedDescription }
    }

    private func receive(_ messages: [MIDIMessage], fromMock: Bool = false) {
        for message in messages { log("IN " + message.description + (fromMock ? " [MOCK]" : "")) }
        guard hardwareMode != fromMock else { return }
        do {
            let update = try session.receive(messages)
            send(update.feedback)
            if !update.inputs.isEmpty { updateBank() }
        } catch { self.error = error.localizedDescription }
    }

    private func apply(_ operation: (inout CompactSession) throws -> [MIDIMessage]) {
        do {
            send(try operation(&session))
            updateBank()
        }
        catch { self.error = error.localizedDescription }
    }

    private func send(_ messages: [MIDIMessage]) {
        for message in messages {
            log("OUT " + message.description + (hardwareMode ? "" : " [MOCK]"))
            guard hardwareMode else {
                mock.receive(message)
                continue
            }
            do { try midi.send(message) }
            catch {
                self.error = error.localizedDescription
                session.invalidateTransportFeedback()
                break
            }
        }
    }

    private func updateBank() { bank = session.bank(layer) }
    private func log(_ entry: String) {
        logs.insert(entry, at: 0)
        if logs.count > 120 { logs.removeLast(logs.count - 120) }
    }
}
#endif
