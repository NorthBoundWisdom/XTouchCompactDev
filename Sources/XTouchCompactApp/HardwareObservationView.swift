#if os(macOS)
    import SwiftUI
    import XTouchCompactCore
    import XTouchCompactLocalization

    private enum ObservationWorkspaceTab: Hashable {
        case panel, review, nonMotor
    }

    /// A passive physical-input workspace. Views consume observations, never the transport.
    struct HardwareObservationView: View {
        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @EnvironmentObject private var language: LanguageSettings
        @State private var inputChoice: Int32 = 0
        @State private var tab: ObservationWorkspaceTab = {
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--nonmotor-tests") || arguments.contains("nonmotor-tests") || arguments.contains("nonmotor-armed") || arguments.contains("nonmotor-result") {
                return .nonMotor
            }
            if arguments.contains("--input-review") || arguments.contains("observation-review") {
                return .review
            }
            return .panel
        }()

        private var l: Localizer {
            language.localizer
        }

        private var observation: HardwareObservationPresentation {
            snapshot.hardwareObservation ?? .init()
        }

        private var connected: Bool {
            snapshot.connection.connectedInput != nil
        }

        var body: some View {
            VStack(spacing: 0) {
                header
                HStack {
                    Picker(l.text("Observation workspace"), selection: $tab) {
                        Text(l.text("Live panel")).tag(ObservationWorkspaceTab.panel)
                        Text(l.text("A/B input review")).tag(ObservationWorkspaceTab.review)
                        Text(l.text("Nonmotor tests")).tag(ObservationWorkspaceTab.nonMotor)
                    }.pickerStyle(.segmented).frame(width: 410)
                    Spacer()
                    if snapshot.capturePath != nil {
                        Label(l.text("Recording inputs"), systemImage: "record.circle.fill")
                            .font(.caption).foregroundStyle(Theme.value)
                        Button(l.text("Stop capture")) { intents.stopCapture?() }
                    } else {
                        Button(l.text("Start capture…")) { intents.startCapture?() }
                    }
                    Button(l.text("Export input review…")) { intents.exportInputReview?() }
                        .disabled(observation.messageCount == 0)
                }.padding(.horizontal, 20).padding(.bottom, 12)
                if let error = snapshot.runtimeError {
                    Label(l.text(error), systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20).padding(.bottom, 10)
                }
                Divider()
                switch tab {
                case .review: HardwareInputReviewView(snapshot: snapshot, intents: intents)
                case .nonMotor: NonMotorTestView(snapshot: snapshot, intents: intents)
                case .panel: livePanel
                }
            }
            .onAppear { inputChoice = snapshot.inputChoice }
            .onChange(of: tab) { previous, current in
                if previous == .nonMotor, current != .nonMotor {
                    intents.lockNonMotorTests?()
                }
            }
        }

        private var livePanel: some View {
            GeometryReader { geometry in
                let scale = min(1.4, max(1, min((geometry.size.width - 380) / PanelMetrics.naturalSize.width,
                                                (geometry.size.height - 210) / PanelMetrics.naturalSize.height)))
                ScrollView([.horizontal, .vertical]) {
                    HStack(alignment: .top, spacing: 18) {
                        VStack(alignment: .leading, spacing: 14) {
                            liveStatus
                            SurfacePanelView(snapshot: snapshot, intents: intents,
                                             selection: .constant(observation.latest?.panelControl), onSelectLayer: { _ in })
                                .environment(\.panelMetrics, PanelMetrics(scale: scale))
                                .allowsHitTesting(false)
                                .disabled(true)
                                .accessibilityHint(l.text("Operate the physical device to update this panel"))
                            coverage
                        }
                        .frame(width: PanelMetrics.naturalSize.width * scale)
                        VStack(spacing: 14) {
                            latestInput
                            selectedReadout
                            connectionControls
                        }
                        .frame(width: 300)
                    }
                    .padding(18)
                    .frame(minWidth: geometry.size.width, alignment: .top)
                }
            }
        }

        private var header: some View {
            HStack(spacing: 16) {
                Image(systemName: "hand.point.up.left.fill")
                    .font(.system(size: 25)).foregroundStyle(Theme.touch)
                VStack(alignment: .leading, spacing: 4) {
                    Text(l.text("Hardware observation")).font(.system(size: 22, weight: .bold))
                    Text(l.text("Touch a fader, turn an encoder or press a button"))
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Label(l.text(snapshot.nonMotorTests.approval == nil ? "Input only · motors locked" : "Nonmotor output enabled · motor commands blocked"), systemImage: "lock.shield.fill")
                    .font(.callout.bold()).foregroundStyle(snapshot.nonMotorTests.approval == nil ? Theme.value : Theme.touch)
                    .padding(10).background(Theme.value.opacity(0.1), in: Capsule())
                Button(l.text("Reset observations")) { intents.resetHardwareObservation?() }
                Button(l.text("Enable writeback")) { intents.enableHardwareWriteback?() }
                Button(l.text("Back to console")) { intents.endHardwareObservation?() }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }

        private var liveStatus: some View {
            HStack(spacing: 14) {
                Circle().fill(connected ? Theme.value : Color.orange).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 4) {
                    Text(observation.isPreview ? l.text("Preview data") : snapshot.connection.connectedInput?.name ?? l.text("Waiting for MIDI input connection"))
                        .font(.subheadline.bold())
                    Text(l.text("Observed inputs: %@", String(observation.messageCount)))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(l.text("Input layer: %@", observation.inputLayer?.rawValue.uppercased() ?? "—"))
                        .font(.subheadline.monospaced().bold())
                    Text(l.text("Layer is identified by the next control input"))
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .panelStyle()
        }

        private var latestInput: some View {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(l.text("Last physical input"), icon: "waveform.path")
                if let latest = observation.latest {
                    HStack(alignment: .firstTextBaseline) {
                        Text(latest.input?.control.shortName ?? "MIDI")
                            .font(.system(size: 36, weight: .black, design: .rounded))
                        Spacer()
                        Text(action(latest)).font(.headline).foregroundStyle(Theme.touch)
                    }
                    if let input = latest.input {
                        Text(input.control.localizedName(using: l)).font(.callout).foregroundStyle(.secondary)
                    }
                    Text(latest.message.description).font(.caption.monospaced()).textSelection(.enabled)
                    Text(latest.message.midi1Bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                        .font(.caption2.monospaced()).foregroundStyle(.secondary)
                    if !latest.matchesConfiguredChannel {
                        Label(l.text("Received channel %@; configured TX is %@", String(latest.channel), String(snapshot.transmitChannel)), systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    } else if latest.input == nil {
                        Text(l.text("Unmapped message · raw input retained"))
                            .font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Image(systemName: "hand.draw").font(.system(size: 38)).foregroundStyle(Theme.touch)
                    Text(l.text("Try touching F1")).font(.title2.bold())
                    Text(l.text("Touch the metal fader cap, then let go. No button press needed."))
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 155, alignment: .topLeading)
            .panelStyle()
        }

        private var selectedReadout: some View {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(l.text("Physical state"), icon: "slider.vertical.3")
                if let control = observation.latest?.panelControl {
                    switch control {
                    case let .fader(index), let .faderTouch(index):
                        HStack(alignment: .firstTextBaseline) {
                            Text("F\(index)").font(.title2.bold())
                            Spacer()
                            Text(observation.faderPositions[index].map { String($0) } ?? "—")
                                .font(.system(size: 44, weight: .medium, design: .monospaced)).foregroundStyle(Theme.value)
                        }
                        Text(l.text("Reported position · 0–127")).font(.caption).foregroundStyle(.secondary)
                        stateBadge(observation.faderTouches[index], down: "Touched", up: "Released")
                    case let .encoder(index), let .encoderPush(index):
                        HStack {
                            Text("E\(index)").font(.title2.bold())
                            Spacer()
                            Text(observation.encoderValue(index).map { String($0) } ?? "—")
                                .font(.system(size: 40, design: .monospaced)).foregroundStyle(Theme.value)
                        }
                        stateBadge(observation.encoderPushes[index], down: "Pressed", up: "Released")
                    case let .button(index):
                        Text("B\(index)").font(.title.bold())
                        stateBadge(observation.buttonPresses[index], down: "Pressed", up: "Released")
                    case .expression:
                        HStack {
                            Text("EXP").font(.title2.bold())
                            Spacer()
                            Text(observation.expressionValue.map { String($0) } ?? "—")
                                .font(.system(size: 40, design: .monospaced)).foregroundStyle(Theme.value)
                        }
                    case .footswitch:
                        Text("SW").font(.title.bold())
                        stateBadge(observation.footswitchDown, down: "Pressed", up: "Released")
                    }
                } else {
                    Text(l.text("No physical state reported yet")).foregroundStyle(.secondary)
                }
                let held = observation.touchedFaders
                if !held.isEmpty {
                    Label(l.text("Touching: %@", held.map { "F\($0)" }.joined(separator: ", ")), systemImage: "hand.raised.fill")
                        .font(.caption.bold()).foregroundStyle(Theme.touch)
                }
                if !connected, !observation.isPreview, observation.messageCount > 0 {
                    Text(l.text("Disconnected · showing last received state"))
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading).panelStyle()
        }

        private func stateBadge(_ state: Bool?, down: String, up: String) -> some View {
            Text(l.text(state.map { $0 ? down : up } ?? "Not reported"))
                .font(.headline).foregroundStyle(state == true ? Theme.touch : Color.secondary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background((state == true ? Theme.touch : Color.secondary).opacity(0.12), in: Capsule())
        }

        private var coverage: some View {
            HStack(spacing: 16) {
                ForEach(observation.coverage) { item in
                    coverageItem(item.title, count: item.count, total: item.total)
                }
            }
            .frame(maxWidth: .infinity).panelStyle()
        }

        private func coverageItem(_ title: String, count: Int, total: Int) -> some View {
            VStack(spacing: 4) {
                Text("\(count) / \(total)").font(.subheadline.monospaced().bold()).foregroundStyle(Theme.value)
                Text(l.text(title)).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
        }

        private var connectionControls: some View {
            VStack(alignment: .leading, spacing: 10) {
                if let path = snapshot.capturePath {
                    Label(l.text("Recording inputs"), systemImage: "record.circle.fill").foregroundStyle(Theme.value)
                    Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption2).textSelection(.enabled)
                    Button(l.text("Stop capture")) { intents.stopCapture?() }
                } else {
                    Button(l.text("Start capture…")) { intents.startCapture?() }
                }
                DisclosureGroup(l.text("MIDI input")) {
                    Picker(l.text("Input"), selection: $inputChoice) {
                        Text(l.text("Auto X-TOUCH COMPACT")).tag(Int32(0))
                        ForEach(snapshot.connection.inputs) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                    Button(l.text("Connect input")) { intents.selectPorts?(inputChoice, snapshot.outputChoice) }
                    Text(l.text("Configured TX: %@ · Global RX: %@", String(snapshot.transmitChannel), String(snapshot.feedbackChannel)))
                        .font(.caption2).foregroundStyle(.secondary)
                }
                if let error = snapshot.runtimeError {
                    Text(l.text(error)).font(.caption).foregroundStyle(.orange)
                }
            }
            .font(.caption).panelStyle()
        }

        private func action(_ event: ObservedHardwareInput) -> String {
            guard let input = event.input else { return l.text("Raw MIDI input") }
            switch input.control {
            case .faderTouch: return l.text(input.isPressed == true ? "Touched" : "Released")
            case .encoderPush, .button, .footswitch: return l.text(input.isPressed == true ? "Pressed" : "Released")
            case .fader, .encoder, .expression: return l.text("Value %@", String(input.value))
            }
        }
    }
#endif
