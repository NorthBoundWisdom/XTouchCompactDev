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
    private var session: CompactSession

    init() {
        let map = try! FactoryStandardMap() // Constant channels are valid by construction.
        session = CompactSession(map: map, lightProtocol: .manual)
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
        do { try midi.start() } catch { self.error = error.localizedDescription }
        updateBank()
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
            layer = .a
            updateBank()
            log("MIDI channel/profile changed; application values reset")
            if hardwareMode && connection.isConnected { apply { try $0.connect() } }
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
        apply { try $0.toggleButton(index) }
        updateBank()
    }

    private func receive(_ messages: [MIDIMessage]) {
        for message in messages { log("IN " + message.description) }
        guard hardwareMode else { return }
        do {
            let update = try session.receive(messages)
            send(update.feedback)
            if !update.inputs.isEmpty { updateBank() }
        } catch { self.error = error.localizedDescription }
    }

    private func apply(_ operation: (inout CompactSession) throws -> [MIDIMessage]) {
        do { send(try operation(&session)) }
        catch { self.error = error.localizedDescription }
    }

    private func send(_ messages: [MIDIMessage]) {
        for message in messages {
            log("OUT " + message.description + (hardwareMode ? "" : " [MOCK]"))
            guard hardwareMode else { continue }
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
