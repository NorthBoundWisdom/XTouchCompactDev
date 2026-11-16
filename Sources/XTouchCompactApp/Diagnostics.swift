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
            var bindingGeneration: UInt64?
            var knownHardwareLayer: CompactLayer?
        }

        var id = UUID()
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
        var monotonicTime: Double?
        var transportMonotonicTime: Double?
        var capturedBindingGeneration: UInt64?
        var capturedHardwareLayer: CompactLayer?
        var decodedInput: CompactInput?
        var plannedProvenance: CompactPlannedProvenance?
    }

    struct ConsoleMutationFact: Equatable, Sendable {
        var id: UUID
        var operation: String
        var targets: [String]
        var accepted: Bool
        var reason: String?
        var routeGeneration: UInt64
        var bindingGeneration: UInt64
        var at: Double
        var values: [String: Double]
    }

    struct ConsoleNotification: Identifiable, Equatable, Sendable {
        enum Level: Sendable { case info, warning, error }
        var id: String
        var level: Level
        var message: LocalizedMessage?
        var persistent: Bool
    }
#endif
