#if os(macOS)
    import Foundation
    import XTouchCompactCore
    import XTouchCompactLocalization

    struct MonitorEvent: Identifiable, Equatable, Sendable {
        enum Direction: String, Sendable { case input = "IN", output = "OUT" }
        enum Source: String, Sendable { case mock, hardware, agent, application }
        let id = UUID()
        var timestamp: Date
        var direction: Direction?
        var source: Source
        var message: MIDIMessage?
        var control: CompactControl?
        var ignored: Bool
        var text: LocalizedMessage
    }

    struct ConsoleNotification: Identifiable {
        enum Level { case info, warning, error }
        var id: String
        var level: Level
        var message: LocalizedMessage?
        var persistent: Bool
    }
#endif
