#if os(macOS)
    import Combine
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore
    import XTouchCompactLocalization

    @Test @MainActor func idleTicksDoNotPublishAndModelOwnsScheduler() async throws {
        let clock = TestClock()
        let model = ConsoleModel(startsMIDI: false, now: { clock.date })
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        for _ in 0 ..< 20 {
            model.advanceAgents()
        }
        #expect(changes == 0)
        model.agentPrimary(1)
        clock.time += 3
        model.startRuntime() // No window or view exists in this test.
        for _ in 0 ..< 100 where model.agents.slots[0].phase == .running {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(model.agents.slots[0].phase == .waitingApproval)
        model.stopRuntime()
        withExtendedLifetime(subscription) {}
    }
#endif
