#if os(macOS)
    import SwiftUI
    import XTouchCompactCore
    import XTouchCompactLocalization

    /// Right-hand inspector for the selected physical control. Sections whose data the backend
    /// does not provide yet are hidden rather than filled with placeholders.
    struct ControlInspectorView: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let snapshot: PanelSnapshot
        let intents: PanelIntents
        let selection: CompactControl?

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let selection {
                        identity(selection)
                        state(selection)
                        if let addressing = intents.addressing?(selection, snapshot.layer) {
                            addresses(addressing)
                        }
                        notes(selection)
                    } else {
                        Text(l.text("在左侧面板选择一个控件"))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 160)
                            .panelStyle()
                    }
                }
                .padding(14)
            }
        }

        private func identity(_ control: CompactControl) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(control.shortName)
                        .font(.system(size: 30, weight: .black, design: .rounded))
                    Text(control.localizedName(using: l)).font(.callout).foregroundStyle(.secondary)
                }
                Text(l.text("Layer %@ · %@", snapshot.layer.rawValue.uppercased(), l.text(snapshot.isMock ? "Mock 设备" : "实体设备")))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            .panelStyle()
        }

        @ViewBuilder
        private func state(_ control: CompactControl) -> some View {
            switch control {
            case let .fader(index), let .faderTouch(index):
                if let fader = snapshot.fader(index) {
                    faderState(fader)
                }
            case let .encoder(index), let .encoderPush(index):
                if let encoder = snapshot.encoder(index) {
                    encoderState(encoder)
                }
            case let .button(index):
                if let button = snapshot.button(index) {
                    buttonState(button)
                }
            case .expression, .footswitch:
                // Pedals are rear-panel accessories without a panel state or feedback address.
                EmptyView()
            }
        }

        private func faderState(_ fader: FaderPresentation) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(l.text("电动推子"), icon: "slider.vertical.3")
                if fader.mirrorsHardware {
                    hardwareReading(fader.hardwareReading)
                }
                HStack(spacing: 18) {
                    readout(l.text("目标"), "\(fader.target)", Theme.value)
                    if !fader.mirrorsHardware, let observed = fader.observed {
                        readout(l.text("实测"), "\(observed)", Theme.observed)
                    }
                    if let touched = fader.isTouched {
                        readout(l.text("触摸"), touched ? l.text("是") : l.text("否"), touched ? Theme.touch : .secondary)
                    }
                }
                if fader.isMotorPending == true {
                    Label(l.text("触摸期间电机指令已暂缓，松开后对位"), systemImage: "hand.raised.fill")
                        .font(.caption)
                        .foregroundStyle(Theme.touch)
                }
                softwareSlider(value: fader.target) { intents.setFader(fader.index, $0) }
                Text(l.text("软件写入会驱动电机；推子被触摸时只更新目标，不与手对抗。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .panelStyle()
        }

        private func encoderState(_ encoder: EncoderPresentation) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(l.text("编码器"), icon: "dial.medium")
                if encoder.mirrorsHardware {
                    hardwareReading(encoder.hardwareReading)
                }
                HStack(spacing: 18) {
                    readout(l.text("数值"), "\(encoder.value)", Theme.value)
                    readout(l.text("灯环"), ringName(encoder.ring), Theme.ring)
                    if let style = encoder.style {
                        readout(l.text("样式"), styleName(style), .secondary)
                    }
                    if let pushed = encoder.isPushed {
                        readout(l.text("按下"), pushed ? l.text("是") : l.text("否"), .secondary)
                    }
                }
                softwareSlider(value: encoder.value) { intents.setEncoder(encoder.index, $0) }
                Text(l.text("灯环只有 13 段；本地转动可能覆盖远程灯环，主机会重发期望位置。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .panelStyle()
        }

        private func buttonState(_ button: ButtonPresentation) -> some View {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(l.text("按键"), icon: "button.programmable")
                HStack(spacing: 18) {
                    readout("LED", lightName(button.light), button.light == .off ? .secondary : Theme.led)
                    if let isDown = button.isDown {
                        readout(l.text("按住"), isDown ? l.text("是") : l.text("否"), .secondary)
                    }
                }
            }
            .panelStyle()
        }

        private func hardwareReading(_ reading: HardwareValuePresentation?) -> some View {
            VStack(alignment: .leading, spacing: 4) {
                Text(reading.map { l.text("Last hardware input: %@", String($0.value)) } ?? l.text("Not reported"))
                    .font(.callout.monospaced()).foregroundStyle(Theme.observed)
                Text(l.text(reading?.isCurrent == true ? "Last received input" : "Last input · awaiting confirmation"))
                    .font(.caption).foregroundStyle(.secondary)
                if let reading {
                    Text(reading.timestamp.formatted(date: .abbreviated, time: .standard))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }

        private func addresses(_ addressing: ControlAddressing) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(l.text("MIDI 地址"), icon: "arrow.left.arrow.right")
                LabeledContent(l.text("输入 (TX)")) { Text(addressing.input).font(.callout.monospaced()) }
                if let feedback = addressing.feedback {
                    LabeledContent(l.text("反馈 (RX)")) { Text(feedback).font(.callout.monospaced()) }
                }
                Text(l.text("输入与反馈地址不同；反馈走单独配置的 Global 通道。"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .panelStyle()
        }

        @ViewBuilder
        private func notes(_ control: CompactControl) -> some View {
            if case let .button(index) = control, index >= 34 {
                Label(l.text("走带区按键按下后设备可能在本地重绘整组 LED，主机会重发期望状态。"), systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .panelStyle()
            }
        }

        // MARK: Pieces

        private func readout(_ title: String, _ value: String, _ color: Color) -> some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.system(.title3, design: .monospaced).bold()).foregroundStyle(color)
            }
        }

        private func softwareSlider(value: UInt8, onChange: @escaping (UInt8) -> Void) -> some View {
            HStack(spacing: 8) {
                Text(l.text("软件写入")).font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: Binding(get: { Double(value) }, set: { onChange(UInt8($0.rounded())) }),
                    in: 0 ... 127
                )
                .accessibilityLabel(l.text("软件写入数值"))
            }
        }

        private func ringName(_ display: RingDisplay) -> String {
            switch display {
            case .off: l.text("关")
            case let .position(position): "\(position)/13"
            case let .blinkingPosition(position): l.text("%@/13 闪", String(position))
            case .allOn: l.text("全亮")
            case .allBlinking: l.text("全闪")
            }
        }

        private func styleName(_ style: RingStyle) -> String {
            switch style {
            case .single: l.text("单点")
            case .pan: "Pan"
            case .fan: "Fan"
            case .spread: "Spread"
            case .trim: "Trim"
            }
        }

        private func lightName(_ light: ButtonLight) -> String {
            switch light {
            case .off: l.text("熄灭")
            case .on: l.text("点亮")
            case .blink: l.text("闪烁")
            }
        }
    }
#endif
