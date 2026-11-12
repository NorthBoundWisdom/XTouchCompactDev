#if os(macOS)
    import SwiftUI
    import XTouchCompactCore
    import XTouchCompactLocalization

    enum WorkspaceTab: String, CaseIterable, Identifiable {
        case values, parameters, organize, agents, monitor, connection

        var id: String {
            rawValue
        }

        var title: String {
            switch self {
            case .values: "数值"
            case .parameters: "Parameters"
            case .organize: "Organize"
            case .agents: "Agents"
            case .monitor: "MIDI 监视"
            case .connection: "连接"
            }
        }

        var systemImage: String {
            switch self {
            case .values: "slider.horizontal.3"
            case .parameters: "list.bullet.rectangle"
            case .organize: "square.stack.3d.up"
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
        @State private var tab: WorkspaceTab

        init(snapshot: PanelSnapshot, intents: PanelIntents, selection: Binding<CompactControl?>, initialTab: WorkspaceTab = .values) {
            self.snapshot = snapshot; self.intents = intents
            _selection = selection; _tab = State(initialValue: initialTab)
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                Picker(l.text("工作区"), selection: $tab) {
                    ForEach(WorkspaceTab.allCases) { Label(l.text($0.title), systemImage: $0.systemImage).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 480)

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
                case .organize: ScrollView { OrganizeWorkspace(snapshot: snapshot, intents: intents) }
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
                            badge: fader.isTouched == true ? l.text("触摸中") : nil,
                            color: fader.color, group: fader.group, link: fader.linkRole
                        ) { intents.setFader(fader.index, $0) }
                    }
                }
                group(l.text("编码器")) {
                    ForEach(snapshot.encoders) { encoder in
                        row(
                            control: .encoder(encoder.index),
                            name: encoder.label ?? CompactControl.encoder(encoder.index).localizedName(using: l),
                            value: encoder.value,
                            badge: nil,
                            color: encoder.color, group: encoder.group, link: nil
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
            color: ParameterColor?, group: String?, link: LinkRole?,
            onChange: @escaping (UInt8) -> Void
        ) -> some View {
            // Same organization cues as the panel: color tag, link role, group highlight.
            let isDimmed = snapshot.highlightedGroup.map { $0 != group } ?? false
            return HStack(spacing: 10) {
                Capsule().fill(color.map(Theme.tag) ?? Color.clear).frame(width: 3, height: 16)
                Button(control.shortName) { selection = control }
                    .buttonStyle(.plain)
                    .font(.caption2.monospaced().bold())
                    .frame(width: 34)
                    .padding(.vertical, 2)
                    .background(Theme.selection.opacity(selection == control ? 0.35 : 0.14), in: Capsule())
                Text(name).lineLimit(1).frame(width: 84, alignment: .leading)
                if let link {
                    let text = switch link {
                    case let .leader(linkName): "⛓ " + linkName
                    case let .member(linkName): "→ " + linkName
                    }
                    Text(text).font(.caption2).foregroundStyle(Theme.touch.opacity(0.9)).lineLimit(1)
                        .frame(maxWidth: 70, alignment: .leading)
                }
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
            .opacity(isDimmed ? 0.35 : 1)
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

    struct ConnectionSettingsView: View {
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

        private var portsChanged: Bool {
            input != snapshot.inputChoice || output != snapshot.outputChoice
        }

        private var profileChanged: Bool {
            tx != snapshot.transmitChannel || rx != snapshot.feedbackChannel || observed != snapshot.observedLEDVariant
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                statusCard
                card(l.text("端口"), icon: "cable.connector.horizontal") {
                    row(l.text("输入")) {
                        Picker(l.text("输入"), selection: $input) {
                            Text(l.text("自动匹配 X-TOUCH COMPACT")).tag(Int32(0))
                            ForEach(snapshot.connection.inputs) { Text(portLabel($0)).tag($0.id) }
                        }
                        .labelsHidden()
                    }
                    row(l.text("输出")) {
                        Picker(l.text("输出"), selection: $output) {
                            Text(l.text("自动匹配 X-TOUCH COMPACT")).tag(Int32(0))
                            ForEach(snapshot.connection.outputs) { Text(portLabel($0)).tag($0.id) }
                        }
                        .labelsHidden()
                    }
                    applyRow(l.text("连接所选端口"), changed: portsChanged,
                             help: l.text("按上面的选择重新连接 MIDI 输入与输出")) { intents.selectPorts?(input, output) }
                    if let host = snapshot.connection.remoteBridgeHost {
                        Label(l.text("Remote hardware via %@ (development). Evidence from this route is not a USB sign-off.", host),
                              systemImage: "network")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                card(l.text("设备配置"), icon: "slider.horizontal.below.rectangle") {
                    Text(l.text("These must match the controller. The app never reads or rewrites the device's own settings."))
                        .font(.caption).foregroundStyle(.secondary)
                    row(l.text("Device sends on")) {
                        channelPicker($tx)
                        Text(l.text("device → app")).font(.caption).foregroundStyle(.secondary)
                    }
                    row(l.text("Device receives on")) {
                        channelPicker($rx)
                        Text(l.text("app → device (Global RX); may differ from the send channel")).font(.caption).foregroundStyle(.secondary)
                    }
                    row(l.text("Button LEDs")) {
                        Picker(l.text("Button LEDs"), selection: $observed) {
                            Text(l.text("Manual: 0 off · 1 on · 2 blink")).tag(false)
                            Text(l.text("Firmware 1.14: 0 off · 2 on · 3 blink")).tag(true)
                        }
                        .labelsHidden().fixedSize()
                    }
                    applyRow(l.text("应用配置"), changed: profileChanged,
                             help: l.text("Profile applied; parameter values preserved")) { intents.configureDevice?(tx, rx, observed) }
                }
                card(l.text("Output"), icon: "arrow.up.right.circle") {
                    Toggle(l.text("Listen only — send no MIDI"), isOn: Binding(
                        get: { snapshot.listenOnly }, set: { intents.setListenOnly?($0) }
                    ))
                    Text(l.text("Hardware starts passively. Turning listening off sends nothing; realign explicitly before output tests."))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(l.text("Realign current layer"), action: { intents.realignLayer?() })
                            .disabled(!snapshot.isMock && snapshot.listenOnly)
                            .help(l.text("Reassert the selected layer and clear mismatch evidence. No motor command is sent, but the device cycles its faders on a layer change. Touch state is kept."))
                        Text(l.text("Sends the layer selection and LED/ring feedback, no motor command. The device may cycle its faders when the layer changes."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Text(l.text("仅支持出厂 Standard MIDI 模式。应用不会改写设备预设，也不会自动切换 MC 模式。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .onAppear(perform: loadApplied)
            // An applied change (also from another window) refreshes the form.
            .onChange(of: snapshot.transmitChannel) { _, _ in loadApplied() }
            .onChange(of: snapshot.feedbackChannel) { _, _ in loadApplied() }
            .onChange(of: snapshot.observedLEDVariant) { _, _ in loadApplied() }
        }

        private func loadApplied() {
            input = snapshot.inputChoice; output = snapshot.outputChoice
            tx = snapshot.transmitChannel; rx = snapshot.feedbackChannel; observed = snapshot.observedLEDVariant
        }

        // MARK: Status

        private var statusCard: some View {
            let connected = snapshot.connection.isConnected
            let color: Color = snapshot.isMock ? Theme.value : connected ? .green : .orange
            let title = snapshot.isMock ? l.text("Mock 设备") : connected ? l.text("Connected") : l.text("Not connected")
            return VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Circle().fill(color).frame(width: 9, height: 9)
                    Text(title).font(.headline)
                    if !snapshot.isMock, connected {
                        Text(l.text(snapshot.listenOnly ? "Listen only" : "Sending enabled"))
                            .font(.caption.bold())
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .foregroundStyle(snapshot.listenOnly ? Theme.touch : Color.green)
                            .background((snapshot.listenOnly ? Theme.touch : Color.green).opacity(0.15), in: Capsule())
                    }
                    Spacer()
                }
                Text(connectionSummary).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                // What is in force right now, independent of unapplied edits below.
                Text(l.text("Applied: sends ch %@ · receives ch %@ · LEDs %@", String(snapshot.transmitChannel),
                            String(snapshot.feedbackChannel), snapshot.observedLEDVariant ? "0 / 2 / 3" : "0 / 1 / 2"))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                if let error = snapshot.connection.error {
                    Text(l.text(error)).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(color.opacity(0.35)) }
        }

        // MARK: Pieces

        private func card(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
            VStack(alignment: .leading, spacing: 8) {
                Label(title, systemImage: icon).font(.subheadline.bold())
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
        }

        private func row(_ title: String, @ViewBuilder content: () -> some View) -> some View {
            HStack(spacing: 8) {
                Text(title).frame(width: 130, alignment: .leading)
                content()
                Spacer(minLength: 0)
            }
        }

        private func channelPicker(_ value: Binding<Int>) -> some View {
            Picker("", selection: value) {
                ForEach(1 ... 16, id: \.self) { Text(String($0)).tag($0) }
            }
            .labelsHidden().frame(width: 64)
        }

        /// The apply button is prominent only while the form differs from what is in force.
        private func applyRow(_ title: String, changed: Bool, help: String, action: @escaping () -> Void) -> some View {
            HStack(spacing: 8) {
                if changed {
                    Button(title, action: action).buttonStyle(.borderedProminent).help(help)
                    Label(l.text("Unapplied changes"), systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(Theme.touch)
                } else {
                    Button(title, action: action).disabled(true).help(help)
                    Label(l.text("Applied"), systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        private func portLabel(_ endpoint: CompactMIDIEndpoint) -> String {
            endpoint.remoteBridgeHost == nil ? endpoint.name : endpoint.name + " · " + l.text("Remote")
        }

        private var connectionSummary: String {
            let input = snapshot.connection.connectedInput?.name ?? "—"
            let output = snapshot.connection.connectedOutput?.name ?? "—"
            return "\(input) → App → \(output)"
        }
    }
#endif
