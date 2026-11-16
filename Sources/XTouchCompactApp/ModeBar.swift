#if os(macOS)
    import SwiftUI
    import XTouchCompactCore
    import XTouchCompactLocalization

    /// Always-visible single-row mode strip: which device, whether output is armed, and the
    /// two actions that depend on it. Explanations are tooltips so the bar keeps one height.
    /// Shown above both the console and the input-check tool so the surrounding layout can
    /// change without losing orientation.
    struct ModeBar: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let snapshot: PanelSnapshot
        let intents: PanelIntents

        private var connected: Bool {
            snapshot.connection.isConnected
        }

        private var needsSync: Bool {
            connected && snapshot.hardwareFeedbackNeedsSync == true
        }

        private var isChecking: Bool {
            snapshot.hardwareObservation != nil
        }

        var body: some View {
            HStack(spacing: 12) {
                // Two devices; whether output is armed is a switch on the hardware side, so
                // picking Hardware always lands on listening and never sends by itself.
                HStack(spacing: 4) {
                    modeButton(identifier: "mode.mock", title: "Mock 设备", icon: "cpu", color: Theme.value, selected: snapshot.mode == .mock) {
                        intents.setMode?(.mock)
                    }
                    modeButton(identifier: "mode.hardware", title: "Hardware", icon: "cable.connector", color: barColor, selected: snapshot.mode != .mock) {
                        if snapshot.mode == .mock {
                            intents.setMode?(.hardwareListen)
                        }
                    }
                }
                .padding(BarMetrics.segmentInset)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: BarMetrics.radius))
                .help(l.text(explanation))

                if snapshot.mode != .mock {
                    // Manual: edits are staged until Send. Live: every edit is transmitted.
                    HStack(spacing: 4) {
                        modeButton(identifier: "mode.manualSend", title: "Manual send", icon: "hand.tap", color: Theme.touch, selected: snapshot.mode == .hardwareListen) {
                            intents.setMode?(.hardwareListen)
                        }
                        modeButton(identifier: "mode.liveSend", title: "Live send", icon: "bolt.fill", color: .green, selected: snapshot.mode == .hardwareSend) {
                            intents.setMode?(.hardwareSend)
                        }
                        .disabled(!connected)
                        .help(l.text(connected ? "Allow the app to send lights, rings and fader commands to the controller"
                                : "Connect the controller first"))
                    }
                    .padding(BarMetrics.segmentInset)
                    .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: BarMetrics.radius))

                    if snapshot.mode == .hardwareListen, !isChecking {
                        Button { intents.sendStaged?() } label: {
                            Label(l.text("Send"), systemImage: "paperplane.fill")
                        }.accessibilityIdentifier("mode.send")
                            .buttonStyle(BarButtonStyle(tint: Theme.touch))
                            .disabled(!connected)
                            .help(l.text("Sends this layer's lights, rings and the nine fader targets once. Touched faders are not moved."))
                        Text(l.text("Edits are staged until you press Send."))
                            .font(.caption).foregroundStyle(Theme.touch).lineLimit(1)
                    }

                    HStack(spacing: 5) {
                        Circle().fill(connected ? Color.green : Color.orange).frame(width: 7, height: 7)
                        Text(connected ? l.text("Connected · RX ch %@", String(snapshot.feedbackChannel)) : l.text("Not connected"))
                            .font(.caption.monospaced())
                            .foregroundStyle(connected ? Color.secondary : Color.orange)
                            .lineLimit(1)
                    }
                    .frame(height: BarMetrics.height)
                    .help(l.text(explanation))
                }
                Spacer(minLength: 8)
                if snapshot.mode == .hardwareSend {
                    // The pending-sync warning lives on the button that resolves it.
                    Button { intents.realignLayer?() } label: {
                        Label(l.text(needsSync ? "Lights not synchronized" : "Sync lights to device"),
                              systemImage: needsSync ? "exclamationmark.triangle.fill" : "lightbulb.max")
                    }.accessibilityIdentifier("mode.syncLights")
                        .buttonStyle(BarButtonStyle(tint: needsSync ? Color.orange : nil))
                        .disabled(!connected)
                        .help((needsSync ? l.text("Lights not synchronized; use Sync lights to assert the layer.") + "\n" : "")
                            + l.text("Sends the layer selection and LED/ring feedback, no motor command. The device may cycle its faders when the layer changes."))
                }
                Button {
                    if isChecking {
                        intents.endHardwareObservation?()
                    } else {
                        intents.beginHardwareObservation?()
                    }
                } label: {
                    Label(l.text(isChecking ? "Close input check" : "Input check tool"), systemImage: "hand.point.up.left.fill")
                }.accessibilityIdentifier("mode.inputCheck")
                    .buttonStyle(BarButtonStyle(tint: isChecking ? Theme.touch : nil))
                    .help(l.text("A diagnostic view of what the controller sends. Opening it switches to Hardware · listen."))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 8)
            .background(barColor.opacity(0.10))
            .overlay(alignment: .bottom) { Rectangle().fill(barColor.opacity(0.55)).frame(height: 2) }
        }

        private var barColor: Color {
            switch snapshot.mode {
            case .mock: Theme.value
            case .hardwareListen: Theme.touch
            case .hardwareSend: .green
            }
        }

        private var explanation: String {
            switch snapshot.mode {
            case .mock: "Simulated device. Nothing reaches the real controller."
            case .hardwareListen: "Edits are staged until you press Send."
            case .hardwareSend: "Sending is on. Use Sync lights to push the current layer and lights."
            }
        }

        private func modeButton(identifier: String, title: String, icon: String, color: Color, selected: Bool, action: @escaping () -> Void) -> some View {
            Button(action: action) {
                Label(l.text(title), systemImage: icon)
                    .font(.callout.weight(selected ? .bold : .regular))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: BarMetrics.height - 2 * BarMetrics.segmentInset)
                    .foregroundStyle(selected ? Color.black : Color.primary.opacity(0.8))
                    .background(selected ? color : Color.clear,
                                in: RoundedRectangle(cornerRadius: BarMetrics.radius - BarMetrics.segmentInset + 1))
                    .contentShape(Rectangle())
            }.accessibilityIdentifier(identifier)
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
#endif
