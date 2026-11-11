#if os(macOS)
import SwiftUI
import XTouchCompactCore

enum WorkspaceTab: String, CaseIterable, Identifiable {
    case values, monitor, connection

    var id: String { rawValue }

    var title: String {
        switch self {
        case .values: "数值"
        case .monitor: "MIDI 监视"
        case .connection: "连接"
        }
    }

    var systemImage: String {
        switch self {
        case .values: "slider.horizontal.3"
        case .monitor: "waveform.path"
        case .connection: "cable.connector.horizontal"
        }
    }
}

struct WorkspaceTabsView: View {
    @ObservedObject var model: ConsoleModel
    let snapshot: PanelSnapshot
    let intents: PanelIntents
    @Binding var selection: CompactControl?
    @State private var tab: WorkspaceTab = .values

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("工作区", selection: $tab) {
                ForEach(WorkspaceTab.allCases) { Label($0.title, systemImage: $0.systemImage).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 420)

            switch tab {
            case .values: ValueListView(snapshot: snapshot, intents: intents, selection: $selection)
            case .monitor: MIDIMonitorView(entries: model.logs)
            case .connection: ConnectionSettingsView(model: model)
            }
        }
        .panelStyle()
    }
}

// MARK: - Values

/// Host-side values of the visible layer. Sliders here are software writes: a fader write may
/// move a motor, exactly as an agent or MCP client would.
private struct ValueListView: View {
    let snapshot: PanelSnapshot
    let intents: PanelIntents
    @Binding var selection: CompactControl?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Layer \(snapshot.layer.rawValue.uppercased()) 的软件数值。拖动滑块是软件写入：推子会驱动电机，编码器会重绘灯环。")
                .font(.caption)
                .foregroundStyle(.secondary)
            group("电动推子") {
                ForEach(snapshot.faders) { fader in
                    row(
                        control: .fader(fader.index),
                        name: fader.label ?? CompactControl.fader(fader.index).localizedName,
                        value: fader.target,
                        badge: fader.isTouched == true ? "触摸中" : nil
                    ) { intents.setFader(fader.index, $0) }
                }
            }
            group("编码器") {
                ForEach(snapshot.encoders) { encoder in
                    row(
                        control: .encoder(encoder.index),
                        name: encoder.label ?? CompactControl.encoder(encoder.index).localizedName,
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
            .accessibilityLabel("\(name) 软件数值")
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
    let entries: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IN = 设备 → 软件，OUT = 软件 → 设备；[MOCK] 表示未发往实体。最新在上。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if entries.isEmpty {
                Text("还没有 MIDI 事件。")
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(entries.prefix(40).enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(entry.hasPrefix("IN") ? Theme.value : Theme.selection)
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
    @ObservedObject var model: ConsoleModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("仅支持出厂 Standard MIDI 模式。应用不会改写设备预设，也不会自动切换 MC 模式。")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                Text("端口").font(.subheadline.bold())
                Picker("输入", selection: $model.inputChoice) {
                    Text("自动匹配 X-TOUCH COMPACT").tag(Int32(0))
                    ForEach(model.connection.inputs) { Text($0.name).tag($0.id) }
                }
                Picker("输出", selection: $model.outputChoice) {
                    Text("自动匹配 X-TOUCH COMPACT").tag(Int32(0))
                    ForEach(model.connection.outputs) { Text($0.name).tag($0.id) }
                }
                HStack {
                    Button("连接所选端口") { model.selectPorts() }
                        .help("按上面的选择重新连接 MIDI 输入与输出")
                    Text(connectionSummary).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))

            VStack(alignment: .leading, spacing: 8) {
                Text("设备配置").font(.subheadline.bold())
                Stepper("发送通道（设备 → 软件）：\(model.transmitChannel)", value: $model.transmitChannel, in: 1 ... 16)
                Stepper("Global 接收通道（软件 → 设备）：\(model.feedbackChannel)", value: $model.feedbackChannel,
                        in: 1 ... 16)
                Toggle("按键 LED 使用固件 1.14 实测值（0 / 2 / 3）", isOn: $model.observedLEDVariant)
                    .help("关闭时按官方手册发送 0 / 1 / 2")
                HStack {
                    Button("应用配置") { model.configure() }
                        .help("重建会话并重置临时数值；不会修改设备预设")
                    Text("应用后软件数值清零。两个通道互相独立，不从收到的消息推断接收通道。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
        }
    }

    private var connectionSummary: String {
        let input = model.connection.connectedInput?.name ?? "—"
        let output = model.connection.connectedOutput?.name ?? "—"
        return "\(input) → App → \(output)"
    }
}
#endif
