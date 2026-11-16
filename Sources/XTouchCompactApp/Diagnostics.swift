#if os(macOS)
    import Foundation
    import XTouchCompactCore
    import XTouchCompactLocalization

    struct MonitorEvent: Identifiable, Equatable, Sendable {
        enum Direction: String, Sendable { case input = "IN", output = "OUT" }
        enum Source: String, Sendable { case mock, hardware, agent, application }
        enum Delivery: String, Sendable { case received, sent, suppressed, failed }
        enum DeviceSource: String, Sendable { case simulation, hardware }
        struct DispatchContext: Equatable, Sendable {
            var transmitChannel: UInt8
            var receiveChannel: UInt8
            var lightProtocol: ButtonLightProtocol
            var listenOnly: Bool
        }

        let id = UUID()
        var timestamp: Date
        var direction: Direction?
        var source: Source
        var message: MIDIMessage?
        var control: CompactControl?
        var hostLayer: CompactLayer
        var deviceLayer: CompactLayer?
        var delivery: Delivery?
        var ignored: Bool
        var text: LocalizedMessage
        var connection: CompactMIDIConnection?
        var nonMotorTest: NonMotorTestAudit?
        var endpointOrigin: CompactEndpointStamp?
        var deviceSource: DeviceSource?
        var dispatchContext: DispatchContext?
    }

    struct ConsoleNotification: Identifiable, Equatable, Sendable {
        enum Level: Sendable { case info, warning, error }
        var id: String
        var level: Level
        var message: LocalizedMessage?
        var persistent: Bool
    }
#endif
