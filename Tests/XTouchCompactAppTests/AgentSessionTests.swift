#if os(macOS)
    import Combine
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore
    import XTouchCompactLocalization

    @Test @MainActor func idleTicksDoNotPublishAndModelOwnsScheduler() async {
        let clock = TestClock()
        let scheduler = TestRuntimeSleeper()
        let model = ConsoleModel(startsMIDI: false, now: { clock.date }, runtimeSleep: scheduler.sleep)
        var changes = 0
        let subscription = model.objectWillChange.sink { changes += 1 }
        for _ in 0 ..< 20 {
            model.advanceAgents()
        }
        #expect(changes == 0)
        model.agentPrimary(1)
        clock.time += 3
        model.startRuntime() // No window or view exists in this test.
        await scheduler.waitUntilSleeping()
        #expect(model.agents.slots[0].phase == .queued)
        scheduler.resume()
        await scheduler.waitUntilSleeping() // The first tick completed before the second wait.
        #expect(model.agents.slots[0].phase == .waitingApproval)
        #expect(scheduler.durations == [.milliseconds(250), .milliseconds(250)])
        model.stopRuntime()
        scheduler.cancel()
        withExtendedLifetime(subscription) {}
    }
#endif
