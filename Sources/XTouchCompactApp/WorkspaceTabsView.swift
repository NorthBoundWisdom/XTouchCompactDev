#if os(macOS)
    import SwiftUI
    import XTouchCompactCore
    import XTouchCompactLocalization

    enum WorkspaceTab: String, CaseIterable, Identifiable {
        case values, parameters, agents, monitor, connection

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .values: "数值"
            case .parameters: "Parameters"
            case .agents: "Agents"
            case .monitor: "MIDI 监视"
            case .connection: "连接"
            }
        }

        var systemImage: String {
            switch self {
            case .values: "slider.horizontal.3"
            case .parameters: "list.bullet.rectangle"
            case .agents: "person.3"
            case .monitor: "waveform.path"
            case .connection: "cable.connector.horizontal"
            }
        }
    }

    struct WorkspaceTabsView: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @Binding var selection: CompactControl?
        @State private var tab: WorkspaceTab = .values

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Picker(l.text("工作区"), selection: $tab) {
                    ForEach(WorkspaceTab.allCases) { Label(l.text($0.title), systemImage: $0.systemImage).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 420)

                switch tab {
                case .agents:
                    VStack {
                        ForEach(snapshot.businessPlugins) { plugin in
                            HStack {
                                Text(l.text(plugin.title))
                                Text(l.text(plugin.state)).foregroundStyle(.secondary)
                                Spacer()
                                if let detail = plugin.detail {
                                    Text(detail).font(.caption.monospacedDigit())
                                }
                            }
                        }
                        ForEach(snapshot.agents) { slot in
                            HStack {
                                Text("Agent \(slot.id)")
                                Text(l.text(slot.phase.rawValue))
                                Spacer()
                                Button(l.text(slot.primaryActionLabelKey)) {
                                    intents.agentPrimary?(slot.id)
                                }
                            }
                        }
                    }
                case .parameters: ParameterWorkspace(snapshot: snapshot, intents: intents)
                case .values: ValueListView(snapshot: snapshot, intents: intents, selection: $selection)
                case .monitor: MIDIMonitorView(snapshot: snapshot, intents: intents)
                case .connection: ConnectionSettingsView(snapshot: snapshot, intents: intents)
                }
            }
            .panelStyle()
        }
    }

    // MARK: - Values

    /// Host-side values of the visible layer. Sliders here are software writes: a fader write may
    /// move a motor, exactly as an agent or MCP client would.
    private struct ValueListView: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @Binding var selection: CompactControl?

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(l.text("Layer %@ 的软件数值。拖动滑块是软件写入：推子会驱动电机，编码器会重绘灯环。", String(snapshot.layer.rawValue.uppercased())))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                group(l.text("电动推子")) {
                    ForEach(snapshot.faders) { fader in
                        row(
                            control: .fader(fader.index),
                            name: fader.label ?? CompactControl.fader(fader.index).localizedName(using: l),
                            value: fader.target,
                            badge: fader.isTouched == true ? l.text("触摸中") : nil
                        ) { intents.setFader(fader.index, $0) }
                    }
                }
                group(l.text("编码器")) {
                    ForEach(snapshot.encoders) { encoder in
                        row(
                            control: .encoder(encoder.index),
                            name: encoder.label ?? CompactControl.encoder(encoder.index).localizedName(using: l),
                            value: encoder.value,
                            badge: nil
                        ) { intents.setEncoder(encoder.index, $0) }
                    }
                }
            }
        }

        private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.bold())
                content()
            }
            .padding(10)
            .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
        }

        private func row(
            control: CompactControl, name: String, value: UInt8, badge: String?,
            onChange: @escaping (UInt8) -> Void
        ) -> some View {
            HStack(spacing: 10) {
                Button(control.shortName) { selection = control }
                    .buttonStyle(.plain)
                    .font(.caption2.monospaced().bold())
                    .frame(width: 34)
                    .padding(.vertical, 2)
                    .background(Theme.selection.opacity(selection == control ? 0.35 : 0.14), in: Capsule())
                Text(name).lineLimit(1).frame(width: 84, alignment: .leading)
                Slider(
                    value: Binding(get: { Double(value) }, set: { onChange(UInt8($0.rounded())) }),
                    in: 0 ... 127
                )
                .accessibilityLabel(l.text("%@ 软件数值", String(name)))
                if let badge {
                    Text(badge).font(.caption2).foregroundStyle(Theme.touch)
                }
                Text("\(value)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(Theme.value)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    // MARK: - MIDI monitor

    private struct MIDIMonitorView: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let snapshot: PanelSnapshot
        let intents: PanelIntents

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text(l.text("IN = 设备 → 软件，OUT = 软件 → 设备；[MOCK] 表示未发往实体。最新在上。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button(l.text("Clear monitor")) { intents.clearMonitor?() }
                    if let path = snapshot.capturePath {
                        Button(l.text("Stop capture")) { intents.stopCapture?() }
                        Text(path).font(.caption).textSelection(.enabled)
                    } else {
                        Button(l.text("Start capture…")) { intents.startCapture?() }
                    }
                }
                Text(l.text("Capture saves every event to JSONL; the screen retains only 120 events."))
                    .font(.caption).foregroundStyle(.secondary)
                if snapshot.events.isEmpty {
                    Text(l.text("还没有 MIDI 事件。"))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(snapshot.events.prefix(40).enumerated()), id: \.offset) { _, entry in
                            Text("\(entry.timestamp.formatted(date: .omitted, time: .standard)) [\(l.text(entry.source.rawValue))] \(l.text(entry.text)) \(entry.control?.shortName ?? "") [\(entry.hostLayer.rawValue.uppercased())] \(entry.delivery?.rawValue ?? "")\(entry.ignored ? " [" + l.text("ignored") + "]" : "")")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(entry.direction == .input ? Theme.value : Theme.selection)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Connection

    private struct ConnectionSettingsView: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @State private var input: Int32 = 0
        @State private var output: Int32 = 0
        @State private var tx = 1
        @State private var rx = 1
        @State private var observed = false

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text(l.text("仅支持出厂 Standard MIDI 模式。应用不会改写设备预设，也不会自动切换 MC 模式。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle(l.text("Listen only — send no MIDI"), isOn: Binding(
                    get: { snapshot.listenOnly }, set: { intents.setListenOnly?($0) }
                ))
                Text(l.text("Hardware starts passively. Turning listening off sends nothing; realign explicitly before output tests."))
                    .font(.caption).foregroundStyle(.secondary)
                Button(l.text("Realign current layer"), action: { intents.realignLayer?() })
                    .disabled(!snapshot.isMock && snapshot.listenOnly)
                    .help(l.text("Reassert the selected layer and clear mismatch evidence; no motor recall or touch reset."))
                VStack(alignment: .leading, spacing: 8) {
                    Text(l.text("端口")).font(.subheadline.bold())
                    Picker(l.text("输入"), selection: $input) {
                        Text(l.text("自动匹配 X-TOUCH COMPACT")).tag(Int32(0))
                        ForEach(snapshot.connection.inputs) { Text($0.name).tag($0.id) }
                    }
                    Picker(l.text("输出"), selection: $output) {
                        Text(l.text("自动匹配 X-TOUCH COMPACT")).tag(Int32(0))
                        ForEach(snapshot.connection.outputs) { Text($0.name).tag($0.id) }
                    }
                    HStack {
                        Button(l.text("连接所选端口")) { intents.selectPorts?(input, output) }
                            .help(l.text("按上面的选择重新连接 MIDI 输入与输出"))
                        Text(connectionSummary).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 8) {
                    Text(l.text("设备配置")).font(.subheadline.bold())
                    Stepper(l.text("发送通道（设备 → 软件）：%@", String(tx)), value: $tx, in: 1 ... 16)
                    Stepper(l.text("Global 接收通道（软件 → 设备）：%@", String(rx)), value: $rx,
                            in: 1 ... 16)
                    Toggle(l.text("按键 LED 使用固件 1.14 实测值（0 / 2 / 3）"), isOn: $observed)
                        .help(l.text("关闭时按官方手册发送 0 / 1 / 2"))
                    HStack {
                        Button(l.text("应用配置")) { intents.configureDevice?(tx, rx, observed) }
                            .help(l.text("Profile applied; parameter values preserved"))
                        Text(l.text("Profile applied; parameter values preserved"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
            }
            .onAppear {
                input = snapshot.inputChoice; output = snapshot.outputChoice
                tx = snapshot.transmitChannel; rx = snapshot.feedbackChannel; observed = snapshot.observedLEDVariant
            }
        }

        private var connectionSummary: String {
            let input = snapshot.connection.connectedInput?.name ?? "—"
            let output = snapshot.connection.connectedOutput?.name ?? "—"
            return "\(input) → App → \(output)"
        }
    }
#endif
