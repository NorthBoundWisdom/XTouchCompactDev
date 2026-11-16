#if os(macOS)
    import Foundation

    @MainActor final class TestClock {
        var time: TimeInterval = 100
        var monotonic: TimeInterval = 1
        var date: Date {
            Date(timeIntervalSince1970: time)
        }
    }

    /// A test owns every scheduler wake-up; neither the model nor this helper waits wall time.
    @MainActor final class TestRuntimeSleeper {
        private var pending: CheckedContinuation<Void, any Error>?
        private var observer: CheckedContinuation<Void, Never>?
        private(set) var durations: [Duration] = []

        func sleep(for duration: Duration) async throws {
            durations.append(duration)
            try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                observer?.resume()
                observer = nil
            }
        }

        func waitUntilSleeping() async {
            guard pending == nil else { return }
            await withCheckedContinuation { observer = $0 }
        }

        func resume() {
            let continuation = pending
            pending = nil
            continuation?.resume()
        }

        func cancel() {
            let continuation = pending
            pending = nil
            continuation?.resume(throwing: CancellationError())
        }
    }

#endif
