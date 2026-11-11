#if os(macOS)
    import Foundation
    import XTouchCompactCore
    import XTouchCompactLocalization

    struct MonitorEvent: Identifiable, Equatable, Sendable {
        enum Direction: String, Sendable { case input = "IN", output = "OUT" }
        enum Source: String, Sendable { case mock, hardware, agent, application }
        enum Delivery: String, Sendable { case received, sent, suppressed, failed }
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
    }

    struct ConsoleNotification: Identifiable, Equatable, Sendable {
        enum Level: Sendable { case info, warning, error }
        var id: String
        var level: Level
        var message: LocalizedMessage?
        var persistent: Bool
    }
#endif
