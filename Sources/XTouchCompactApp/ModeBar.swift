#if os(macOS)
    import SwiftUI
    import XTouchCompactCore
    import XTouchCompactLocalization

    /// Always-visible mode strip: where you are, what that mode does, and the two actions
    /// that depend on it. Shown above both the console and the input-check tool so the
    /// surrounding layout can change without losing orientation.
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

        private var isChecking: Bool {
            snapshot.hardwareObservation != nil
        }

        var body: some View {
            HStack(spacing: 12) {
                HStack(spacing: 4) {
                    modeButton(.mock, title: "Mock 设备", icon: "cpu", color: Theme.value)
                    modeButton(.hardwareListen, title: "Hardware · listen", icon: "ear", color: Theme.touch)
                    modeButton(.hardwareSend, title: "Hardware · send", icon: "arrow.up.right.circle.fill", color: .green)
                        .disabled(!connected)
                        .help(l.text(connected ? "Allow the app to send lights, rings and fader commands to the controller"
                                : "Connect the controller first"))
                }
                .padding(3)
                .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 1) {
                    Text(l.text(explanation)).font(.caption).foregroundStyle(.primary.opacity(0.9)).lineLimit(1)
                    if snapshot.mode != .mock {
                        Text(connected ? l.text("Controller connected · receives on ch %@", String(snapshot.feedbackChannel))
                            : l.text("Controller not connected"))
                            .font(.caption2.monospaced())
                            .foregroundStyle(connected ? Color.secondary : Color.orange)
                    }
                }
                Spacer(minLength: 8)
                if snapshot.mode == .hardwareSend {
                    Button { intents.realignLayer?() } label: {
                        Label(l.text("Sync lights to device"), systemImage: "lightbulb.max")
                    }
                    .disabled(!connected)
                    .help(l.text("Sends the layer selection and LED/ring feedback, no motor command. The device may cycle its faders when the layer changes."))
                }
                Button {
                    if isChecking {
                        intents.endHardwareObservation?()
                    } else {
                        intents.beginHardwareObservation?()
                    }
                } label: {
                    Label(l.text(isChecking ? "Close input check" : "Input check tool"), systemImage: "hand.point.up.left.fill")
                }
                .tint(isChecking ? Theme.touch : nil)
                .help(l.text("A diagnostic view of what the controller sends. Opening it switches to Hardware · listen."))
            }
            .controlSize(.small)
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
            case .hardwareListen: "Receiving from the controller. Nothing is sent to it."
            case .hardwareSend: "Sending is on. Use Sync lights to push the current layer and lights."
            }
        }

        private func modeButton(_ mode: ConsoleMode, title: String, icon: String, color: Color) -> some View {
            let selected = snapshot.mode == mode
            return Button { intents.setMode?(mode) } label: {
                Label(l.text(title), systemImage: icon)
                    .font(.callout.weight(selected ? .bold : .regular))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .foregroundStyle(selected ? Color.black : Color.primary.opacity(0.8))
                    .background(selected ? color : Color.clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
    }
#endif
