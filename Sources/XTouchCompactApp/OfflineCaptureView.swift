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
                    Text(l.text("Read-only offline review. No MIDI is sent; recorded evidence is not hardware qualification."))
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
