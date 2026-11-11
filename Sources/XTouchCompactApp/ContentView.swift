#if os(macOS)
    import SwiftUI
    import XTouchCompactCore
    import XTouchCompactLocalization

    struct ContentView: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @State private var selection: CompactControl? = .fader(1)

        var body: some View {
            VStack(spacing: 0) {
                HeaderBar(snapshot: snapshot, intents: intents)
                ForEach(snapshot.notifications) { notification in
                    HStack {
                        ErrorBanner(text: notification.message.map { l.text($0) } ?? snapshot.runtimeError.map { l.text($0) } ?? "", level: notification.level)
                        if notification.persistent {
                            Button(l.text("Retry save")) { intents.retrySave?() }
                        } else {
                            Button(l.text("Dismiss")) { intents.dismissNotification?(notification.id) }
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 10)
                }
                Divider()
                GeometryReader { proxy in
                    let inspectorWidth = min(max(proxy.size.width * 0.24, 300), 380)
                    HStack(spacing: 0) {
                        SurfaceArea(snapshot: snapshot, intents: intents, selection: $selection)
                        Divider()
                        ControlInspectorView(snapshot: snapshot, intents: intents, selection: selection)
                            .frame(width: inspectorWidth)
                    }
                }
            }
            .background(Theme.background)
            .preferredColorScheme(.dark)
        }
    }

    /// Chooses the panel scale and arrangement for the space left of the inspector.
    ///
    /// - Side by side: the workspace sits right of the panel when at least `minWorkspace` points
    ///   remain; the panel grows up to the available height.
    /// - Stacked: the workspace sits below; the panel grows with width but leaves `peek` points of
    ///   the workspace visible.
    struct ConsoleLayout: Equatable {
        static let padding: CGFloat = 18
        static let gap: CGFloat = 16
        static let minWorkspace: CGFloat = 400
        static let maxWorkspace: CGFloat = 720
        static let peek: CGFloat = 150

        let scale: CGFloat
        let isSideBySide: Bool
        let workspaceWidth: CGFloat

        var panelWidth: CGFloat {
            PanelMetrics.naturalSize.width * scale
        }

        var contentWidth: CGFloat {
            isSideBySide ? panelWidth + Self.gap + workspaceWidth : panelWidth
        }

        init(available: CGSize) {
            let natural = PanelMetrics.naturalSize
            let range = PanelMetrics.scaleRange
            let width = available.width - Self.padding * 2
            let height = available.height - Self.padding * 2
            func clamp(_ value: CGFloat) -> CGFloat {
                min(max(value, range.lowerBound), range.upperBound)
            }

            let sideScale = clamp(min((width - Self.gap - Self.minWorkspace) / natural.width, height / natural.height))
            let remaining = width - Self.gap - natural.width * sideScale
            if remaining >= Self.minWorkspace {
                scale = sideScale
                isSideBySide = true
                workspaceWidth = min(remaining, Self.maxWorkspace)
            } else {
                scale = clamp(min(width / natural.width, (height - Self.peek) / natural.height))
                isSideBySide = false
                workspaceWidth = natural.width * scale
            }
        }
    }

    private struct SurfaceArea: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @Binding var selection: CompactControl?

        var body: some View {
            GeometryReader { proxy in
                let layout = ConsoleLayout(available: proxy.size)
                ScrollView([.vertical, .horizontal]) {
                    Group {
                        if layout.isSideBySide {
                            HStack(alignment: .top, spacing: ConsoleLayout.gap) { content(layout) }
                        } else {
                            VStack(spacing: ConsoleLayout.gap) { content(layout) }
                        }
                    }
                    .padding(ConsoleLayout.padding)
                    // Centered whenever the window is wider than the content.
                    .frame(minWidth: proxy.size.width, alignment: .top)
                }
            }
        }

        @ViewBuilder
        private func content(_ layout: ConsoleLayout) -> some View {
            SurfacePanelView(snapshot: snapshot, intents: intents, selection: $selection,
                             onSelectLayer: { intents.selectLayer?($0) })
                .environment(\.panelMetrics, PanelMetrics(scale: layout.scale))
            WorkspaceTabsView(snapshot: snapshot, intents: intents, selection: $selection)
                .frame(width: layout.workspaceWidth)
        }
    }

    private struct HeaderBar: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @State private var confirmsRecall = false

        var body: some View {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("X-TOUCH CONSOLE")
                        .font(.system(size: 20, weight: .black, design: .rounded))
                        .tracking(1.6)
                    if !snapshot.isMock, snapshot.listenOnly {
                        Text(l.text("Listen only — send no MIDI")).font(.caption).foregroundStyle(Theme.touch)
                    }
                    Text("Standard MIDI · Layer \(snapshot.layer.rawValue.uppercased())")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }

                Picker(l.text("设备"), selection: Binding(get: { !snapshot.isMock }, set: { intents.useHardware?($0) })) {
                    Text(l.text("Mock 设备")).tag(false)
                    Text(l.text("实体 X-TOUCH")).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 240)

                Spacer()

                Button { confirmsRecall = true } label: {
                    Label(l.text("电机归位…"), systemImage: "arrow.up.and.down.and.sparkles")
                }
                .controlSize(.small)
                .disabled(snapshot.isMock || snapshot.listenOnly || !snapshot.connection.isConnected)
                .help(l.text("把九个电动推子移动到当前层的软件数值；只在你确认后执行"))
                .confirmationDialog(l.text("移动全部九个实体推子？"), isPresented: $confirmsRecall) {
                    Button(l.text("移动九个电动推子")) { intents.recallMotors?() }
                    Button(l.text("取消"), role: .cancel) {}
                } message: {
                    Text(l.text("连接或换层后不会自动移动电机。请确认推子行程内没有遮挡；被触摸的推子不会移动。"))
                }

                SettingsLink { Label(l.text("Settings"), systemImage: "gearshape") }
                    .labelStyle(.iconOnly).help(l.text("Settings"))
                DeviceStatus(snapshot: snapshot)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }
    }

    private struct DeviceStatus: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let snapshot: PanelSnapshot

        var body: some View {
            let connected = snapshot.connection.isConnected
            let color: Color = !snapshot.isMock ? (connected ? .green : .orange) : Theme.value
            HStack(spacing: 10) {
                Image(systemName: !snapshot.isMock
                    ? (connected ? "cable.connector.horizontal" : "cable.connector.slash") : "cpu")
                    .foregroundStyle(color)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.callout.bold()).foregroundStyle(color)
                    Text(detail).font(.caption2.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .frame(maxWidth: 360, alignment: .trailing)
            .accessibilityElement(children: .combine)
        }

        private var title: String {
            guard !snapshot.isMock else { return l.text("Mock 设备运行中") }
            return snapshot.connection.isConnected ? l.text("X-TOUCH COMPACT 已连接") : l.text("X-TOUCH COMPACT 未连接")
        }

        private var detail: String {
            let hardware = snapshot.connection.isConnected
                ? "\(snapshot.connection.connectedInput?.name ?? "—") → \(snapshot.connection.connectedOutput?.name ?? "—")"
                : (snapshot.connection.error.map { l.text($0) } ?? l.text("未找到完整的输入 / 输出端口"))
            return !snapshot.isMock ? hardware : l.text("实体：%@", String(hardware))
        }
    }

    private struct ErrorBanner: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let text: String
        var level: ConsoleNotification.Level = .error
        private var tint: Color {
            switch level { case .info: .blue; case .warning: .orange; case .error: .red }
        }

        private var symbol: String {
            switch level { case .info: "info.circle.fill"; case .warning: "exclamationmark.triangle.fill"; case .error: "xmark.octagon.fill" }
        }

        var body: some View {
            HStack(spacing: 10) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(text).font(.callout).textSelection(.enabled)
                Spacer()
            }
            .padding(10)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
            .overlay { RoundedRectangle(cornerRadius: 9).stroke(tint.opacity(0.25)) }
        }
    }
#endif
