#if os(macOS)
    import Foundation

    @MainActor final class TestClock {
        var time: TimeInterval = 100
        var date: Date {
            Date(timeIntervalSince1970: time)
        }
    }

#endif
