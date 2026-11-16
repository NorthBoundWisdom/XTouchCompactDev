#if os(macOS) && DEBUG
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @Test @MainActor func isolatedTokenActionReportsFeedbackAndNormalAdapterHasNoAcceptanceHooks() {
        let isolated = ConsoleModel(startsMIDI: false, isolated: true)
        isolated.copyMCPToken()
        #expect(isolated.mcpTokenCopyCount == 1)
        #expect(isolated.panelSnapshot.mcpTokenCopyStatus == "Access token copied.")
        #expect(!isolated.mcpEnabled && !isolated.mcpWritesAllowed && !isolated.mcpMotorWritesAllowed)
        let normal = ConsoleModel(startsMIDI: false)
        normal.integrationUIActive = true
        #expect(normal.panelSnapshot.integrationSummary.isEmpty)
        #expect(normal.panelIntents.integrationAgentWrite == nil && normal.panelIntents.integrationCapture == nil)
    }

    @MainActor private final class ReplayYieldGate {
        private var suspended: CheckedContinuation<Void, Never>?
        private var observer: CheckedContinuation<Void, Never>?
        func suspend() async {
            await withCheckedContinuation { suspended = $0; observer?.resume(); observer = nil }
        }

        func wait() async {
            if suspended != nil {
                return
            }
            await withCheckedContinuation { observer = $0 }
        }

        func resume() {
            suspended?.resume(); suspended = nil
        }
    }

    @Test @MainActor func injectedPlaybackYieldKeepsPauseResetDeterministicWithoutSleepingOrTouchingLiveState() async throws {
        let sample = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures/Capture/xtouch-sample.jsonl")
        let rows = try String(contentsOf: sample, encoding: .utf8).split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        var expanded = [rows[0]]
        for _ in 0 ..< 10 {
            for var event in rows.dropFirst().dropLast() {
                event["sequence"] = expanded.count; expanded.append(event)
            }
        }
        var end = try #require(rows.last); end["eventCount"] = expanded.count - 1; expanded.append(end)
        var data = Data()
        for row in expanded {
            try data.append(JSONSerialization.data(withJSONObject: row)); data.append(10)
        }
        let gate = ReplayYieldGate()
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true, offlineReplayYield: { await gate.suspend() })
        model.importOfflineCapture(data: data, name: "derived-mock.jsonl")
        let before = model.session.parameters.values
        model.runOfflineReplay()
        let task = try #require(model.offlineReplayTask)
        await gate.wait()
        #expect(model.offlineCaptureState.isPlaying && model.offlineCaptureState.replay?.cursor == 128)
        model.pauseOfflineReplay(); model.resetOfflineReplay()
        gate.resume(); await task.value
        #expect(!model.offlineCaptureState.isPlaying && model.offlineCaptureState.replay?.cursor == 0)
        #expect(model.session.parameters.values == before && midi.sent.isEmpty)
    }
#endif
