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
    func start() throws { starts += 1 }
    func select(inputID: Int32?, outputID: Int32?) {}
    func send(_ message: MIDIMessage) throws {
        if fails { throw CompactMIDIError.outputUnavailable }
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
    model.useHardware(true)
    #expect(model.error != nil)
    model.dismissNotification("runtime")
    #expect(model.error == nil)
    service.connect()
    #expect(!service.sent.contains { if case let .controlChange(_, n, _) = $0 { return (1...9).contains(n) }; return false })
    model.faderChanged(1, value: 80)
    #expect(service.sent.last == .controlChange(channel: 0, number: 1, value: 80))
    service.fails = true
    model.faderChanged(1, value: 90)
    #expect(model.error != nil)
    service.fails = false
    service.onConnection?(CompactMIDIConnection())
    service.sent.removeAll()
    service.connect()
    #expect(!service.sent.contains { if case let .controlChange(_, n, _) = $0 { return (1...9).contains(n) }; return false })
    service.onMessages?([.controlChange(channel: 5, number: 1, value: 1)])
    #expect(model.events.first?.ignored == true)
    #expect(model.events.first?.timestamp == Date(timeIntervalSince1970: 123))
    model.clearMonitor()
    #expect(model.events.isEmpty)
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
    #expect(!model.events.contains { if case let .controlChange(_, n, _) = $0.message { return (1...9).contains(n) }; return false })
    model.clearMonitor()
    model.touchFader(1, isTouched: false)
    #expect(!model.events.contains { $0.direction == .output && $0.control == .fader(1) })
}
#endif
