#if os(macOS)
    import SwiftUI
    import XTouchCompactCore
    import XTouchCompactLocalization

    struct OfflineCaptureView: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let snapshot: PanelSnapshot
        let intents: PanelIntents

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Button(l.text("Open capture…")) { intents.openOfflineCapture?() }
                            .disabled(intents.openOfflineCapture == nil)
                        Button(l.text("Clear offline review")) { intents.clearOfflineCapture?() }
                            .disabled(intents.clearOfflineCapture == nil || snapshot.offlineCapture?.name == nil && snapshot.offlineCapture?.isLoading != true)
                        if snapshot.offlineCapture?.isLoading == true {
                            ProgressView().controlSize(.small)
                        }
                    }
                    Text(l.text("Offline actions send no MIDI; the live console keeps its mode. Recorded evidence is not hardware qualification."))
                        .font(.caption).foregroundStyle(.secondary)
                    if let state = snapshot.offlineCapture {
                        if let failure = state.failure {
                            Text(l.text(failure)).foregroundStyle(.red)
                        }
                        if let name = state.name {
                            Text(name).font(.headline).textSelection(.enabled)
                        }
                        if let hash = state.sha256 {
                            Text("SHA-256: " + hash).font(.caption.monospaced()).textSelection(.enabled)
                        }
                        if let replay = state.replay {
                            replayView(replay, loading: state.isLoading)
                        }
                        if let audit = state.audit {
                            auditView(audit)
                        } else {
                            Text(l.text("No capture imported.")).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }

        private func replayView(_ replay: OfflineReplayPresentation, loading: Bool) -> some View {
            GroupBox(l.text("Isolated Mock replay")) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(l.text("Recorded OUT is skipped. Only this isolated Mock can receive generated feedback."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(l.text("Replay uses neutral parameters, not the original assignments or software writes. Actions are not executed; timing follows sequence order."))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(l.text("Step replay")) { intents.stepOfflineReplay?() }
                            .disabled(loading || replay.isPlaying || replay.cursor >= replay.eventCount || intents.stepOfflineReplay == nil)
                        Button(l.text("Run to end")) { intents.runOfflineReplay?() }
                            .disabled(loading || replay.isPlaying || replay.cursor >= replay.eventCount || intents.runOfflineReplay == nil)
                        Button(l.text("Pause replay")) { intents.pauseOfflineReplay?() }
                            .disabled(!replay.isPlaying || intents.pauseOfflineReplay == nil)
                        Button(l.text("Reset replay")) { intents.resetOfflineReplay?() }
                            .disabled(loading || intents.resetOfflineReplay == nil)
                    }
                    ProgressView(value: Double(replay.cursor), total: Double(max(replay.eventCount, 1)))
                    Text(l.text("Replay progress %@ / %@", String(replay.cursor), String(replay.eventCount))).font(.caption.monospacedDigit())
                    Text(l.text("Host %@ · input evidence %@ · simulation TX %@ / RX %@", replay.hostLayer.rawValue.uppercased(),
                                replay.inputLayer?.rawValue.uppercased() ?? "—", String(replay.simulationTX), String(replay.simulationRX)))
                        .font(.caption.monospacedDigit())
                    if replay.usesFallbackProfile {
                        Text(l.text("Missing header profile facts use simulation defaults until recorded metadata is available."))
                            .font(.caption).foregroundStyle(.orange)
                    }
                    if let key = replay.dispositionKey {
                        Text(l.text(key)).font(.caption.bold())
                    }
                    if let message = replay.lastMessage {
                        Text(message).font(.caption.monospaced())
                    }
                    Text(l.text("Replayed inputs %@ · skipped recorded outputs %@ · simulated feedback %@", String(replay.inputsReplayed),
                                String(replay.recordedOutputsSkipped), String(replay.generatedFeedbackCount))).font(.caption.monospacedDigit())
                    Text(l.text("State boundaries %@ · unexecuted actions %@", String(replay.boundaryCount), String(replay.ignoredActionCount)))
                        .font(.caption.monospacedDigit())
                    Divider()
                    Text(l.text("Test targets (Mock only)")).font(.caption.bold())
                    ForEach(replay.faders) { fader in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("F\(fader.index)").font(.caption.monospaced()).frame(width: 26)
                                Slider(value: Binding(get: { Double(fader.target) }, set: {
                                    intents.setOfflineReplayFader?(fader.index, UInt8($0.rounded()))
                                }), in: 0 ... 127)
                                    .disabled(loading || replay.isPlaying || intents.setOfflineReplayFader == nil)
                                    .accessibilityLabel(l.text("Replay test target F%@", String(fader.index)))
                                Text(String(fader.target)).font(.caption.monospacedDigit()).frame(width: 30)
                                if fader.touched {
                                    Text(l.text("Replay touch owned")).font(.caption2).foregroundStyle(.orange)
                                }
                                if fader.pending {
                                    Text(l.text("Replay motor deferred")).font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            Text(l.text("Mock cap %@ · recorded position %@", String(fader.simulatedPosition), fader.observed.map(String.init) ?? "—"))
                                .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }
        }

        private func auditView(_ audit: CaptureMotorAudit) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                Text(l.text(assessmentKey(audit.assessment)))
                    .font(.headline).foregroundStyle(audit.assessment == .violations ? Color.red : audit.assessment == .inconclusive ? Color.orange : Color.primary)
                Text(l.text("Events %@ · motor outputs %@ · layer assertions %@", String(audit.eventCount), String(audit.motorOutputs), String(audit.layerAssertions)))
                    .font(.caption.monospacedDigit())
                Text(l.text(audit.complete ? "Complete capture" : "Incomplete capture prefix")).font(.caption)
                findings("Motor output while touched", audit.motorWhileTouched)
                findings("Motor output during known layer mismatch", audit.motorDuringLayerMismatch)
                findings("Layer assertion while touched", audit.layerAssertionWhileTouched)
                findings("Motor output with unknown touch", audit.motorWithUnknownTouch)
                findings("Motor output with unknown layer", audit.motorWithUnknownLayer)
                findings("Motor output with unknown route", audit.motorWithUnknownRoute)
                findings("Layer assertion with incomplete touch evidence", audit.layerAssertionWithUnknownTouch)
                findings("Layer assertion with unknown route", audit.layerAssertionWithUnknownRoute)
                findings("Output with unknown delivery", audit.outputsWithUnknownDelivery)
                if !audit.releaseWindows.isEmpty {
                    Divider()
                    Text(l.text("Outputs after each release")).font(.headline)
                    Text(l.text("Counts include later explicit writes until the next touch or state boundary; they do not prove release catch-up."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(audit.releaseWindows.prefix(100).enumerated()), id: \.offset) { _, window in
                        Text(l.text("F%@ · release #%@ → #%@ · %@ motor outputs", String(window.fader), String(window.releaseSequence), String(window.endSequence), String(window.motorCount)))
                            .font(.caption.monospacedDigit())
                    }
                    if audit.releaseWindows.count > 100 {
                        Text(l.text("Showing the first 100 release windows; totals use the full capture.")).font(.caption)
                    }
                }
            }
        }

        private func findings(_ key: String, _ sequences: [Int]) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(l.text(key) + ": " + String(sequences.count)).font(.caption.bold())
                if !sequences.isEmpty {
                    Text(sequences.prefix(200).map { "#\($0)" }.joined(separator: ", "))
                        .font(.caption2.monospaced()).textSelection(.enabled)
                    if sequences.count > 200 {
                        Text(l.text("Showing the first 200 matching sequences.")).font(.caption2)
                    }
                }
            }
        }

        private func assessmentKey(_ assessment: CaptureAuditAssessment) -> String {
            switch assessment {
            case .violations: "Recorded violations"
            case .inconclusive: "Insufficient recorded evidence"
            case .noRecordedViolations: "No recorded violations"
            }
        }
    }
#endif
