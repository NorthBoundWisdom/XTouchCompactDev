#if os(macOS)
    import SwiftUI
    import XTouchCompactCore
    import XTouchCompactLocalization

    struct NonMotorTestView: View {
        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @EnvironmentObject private var language: LanguageSettings
        @State private var prerequisites = NonMotorTestPrerequisites()
        @State private var command = NonMotorCommandDraft()
        @State private var responseNote = ""
        private var l: Localizer {
            language.localizer
        }

        private var state: NonMotorTestPresentation {
            snapshot.nonMotorTests
        }

        private var isPreview: Bool {
            snapshot.hardwareObservation?.isPreview == true
        }

        private var previewMatches: Bool {
            let channel = state.approval?.prerequisites.receiveChannel ?? prerequisites.receiveChannel
            return state.preview?.command == command.command && state.preview?.receiveChannel == channel.map { Int($0) + 1 }
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    intro
                    if let approval = state.approval {
                        approvalSummary(approval)
                    } else {
                        prerequisitesForm
                    }
                    HStack(alignment: .top, spacing: 16) {
                        commandForm.frame(maxWidth: .infinity)
                        latestAttempt.frame(maxWidth: .infinity)
                    }
                    history
                }
                .padding(18).frame(maxWidth: 1400).frame(maxWidth: .infinity)
            }
            .allowsHitTesting(!isPreview)
            .onDisappear { intents.lockNonMotorTests?() }
            .onChange(of: snapshot.connection.generation) { _, _ in prerequisites = .init() }
        }

        private var intro: some View {
            VStack(alignment: .leading, spacing: 8) {
                Label(l.text("Stage 2 · nonmotor tests"), systemImage: "lightbulb.led.fill").font(.title2.bold())
                if isPreview {
                    Text(l.text("Preview data")).foregroundStyle(Theme.touch)
                }
                Text(l.text("One explicit command at a time: button light, encoder ring or layer assertion."))
                Text(l.text("Review Stage 1 and independently read Global RX first. Keep fader travel unobstructed."))
                    .foregroundStyle(.secondary)
                Text(l.text("Sending is not device acknowledgement. Record the physical response separately."))
                    .font(.caption).foregroundStyle(Theme.touch)
                if let reason = state.lastLockReason {
                    Text(l.text(reason)).font(.caption).foregroundStyle(.orange)
                }
            }.panelStyle()
        }

        private var prerequisitesForm: some View {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(l.text("Operator prerequisites"), icon: "checklist")
                Toggle(l.text("I confirmed factory Standard MIDI mode"), isOn: $prerequisites.standardModeConfirmed)
                Toggle(l.text("I reviewed complete Stage 1 input and cross-layer evidence"), isOn: $prerequisites.stage1Reviewed)
                TextField(l.text("Stage 1 evidence file or review reference"), text: $prerequisites.stage1Evidence)
                HStack {
                    TextField(l.text("Firmware version read from the device/editor"), text: $prerequisites.firmware)
                    Picker(l.text("Independently confirmed Global RX"), selection: $prerequisites.receiveChannel) {
                        Text("—").tag(UInt8?.none)
                        ForEach(0 ..< 16, id: \.self) { Text("ch\($0 + 1)").tag(Optional(UInt8($0))) }
                    }.frame(width: 380)
                }
                TextField(l.text("Where Global RX was independently checked"), text: $prerequisites.receiveChannelEvidence)
                Text(l.text("Do not use incoming TX as proof of Global RX. Test settings do not rewrite the device profile."))
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button(l.text("Enable nonmotor test output")) { intents.armNonMotorTests?(prerequisites) }
                        .disabled(!state.canRequestPermission || !prerequisites.isComplete)
                    if !state.canRequestPermission {
                        Text(l.text("Connect both endpoints and start recording first.")).font(.caption).foregroundStyle(.orange)
                    }
                }
            }.textFieldStyle(.roundedBorder).panelStyle()
        }

        private func approvalSummary(_ approval: NonMotorTestApproval) -> some View {
            HStack(alignment: .top, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Label(l.text("Nonmotor test output enabled"), systemImage: "lightbulb.led.fill").foregroundStyle(Theme.touch)
                    Text(l.text("Operator firmware: %@ · test RX: %@", approval.prerequisites.firmware,
                                approval.prerequisites.receiveChannel.map { String(Int($0) + 1) } ?? "—"))
                    Text(approval.prerequisites.stage1Evidence).font(.caption).textSelection(.enabled)
                    Text(approval.prerequisites.receiveChannelEvidence).font(.caption).textSelection(.enabled)
                }
                Spacer()
                Button(l.text("Lock test output")) { intents.lockNonMotorTests?() }.tint(.orange)
            }.panelStyle()
        }

        private var commandForm: some View {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(l.text("Single command"), icon: "slider.horizontal.3")
                Picker(l.text("Test type"), selection: $command.kind) {
                    ForEach(NonMotorCommandKind.allCases) { Text(l.text($0.titleKey)).tag($0) }
                }
                switch command.kind {
                case .button:
                    Stepper(l.text("Button %@", String(command.button)), value: $command.button, in: 1 ... 39)
                    Picker(l.text("LED encoding"), selection: $command.variant) {
                        Text(l.text("Manual · 0/1/2")).tag(ButtonLightProtocol.manual)
                        Text(l.text("Observed 1.14 · 0/2/3")).tag(ButtonLightProtocol.observed114)
                    }
                    Picker(l.text("Desired light"), selection: $command.light) {
                        Text(l.text("Off")).tag(ButtonLight.off)
                        Text(l.text("On")).tag(ButtonLight.on)
                        Text(l.text("Blink")).tag(ButtonLight.blink)
                    }.pickerStyle(.segmented)
                case .ring:
                    encoderSelector
                    Picker(l.text("Ring command"), selection: $command.ring) {
                        ForEach(NonMotorRingChoice.allCases) { Text(l.text($0.rawValue)).tag($0) }
                    }
                    if command.ring == .position || command.ring == .blinkingPosition {
                        Stepper(l.text("Segment %@ / 13", String(command.segment)), value: $command.segment, in: 1 ... 13)
                    }
                case .style:
                    encoderSelector
                    Picker(l.text("Ring style"), selection: $command.style) {
                        ForEach(RingStyle.allCases, id: \.self) { Text(l.text(String(describing: $0))).tag($0) }
                    }
                case .layer:
                    Picker(l.text("Requested layer"), selection: $command.layer) {
                        ForEach(CompactLayer.allCases, id: \.self) { Text($0.rawValue.uppercased()).tag($0) }
                    }.pickerStyle(.segmented)
                    Text(l.text("After the assertion, turn E1 to check the received input layer."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(l.text("Preview command")) { intents.previewNonMotorTest?(command.command, prerequisites.receiveChannel) }
                    Button(l.text("Send once")) { intents.performNonMotorTest?(command.command) }
                        .disabled(state.approval == nil || !previewMatches || snapshot.listenOnly)
                }
                if let preview = state.preview {
                    Text(preview.message.description).font(.body.monospaced()).textSelection(.enabled)
                    Text(preview.message.midi1Bytes.map { String(format: "%02X", $0) }.joined(separator: " "))
                        .font(.caption.monospaced()).foregroundStyle(.secondary)
                    if !previewMatches {
                        Text(l.text("Selection changed; preview again before sending.")).font(.caption).foregroundStyle(.orange)
                    }
                } else {
                    Text(l.text("Select a test RX channel and preview this command before sending.")).font(.caption).foregroundStyle(.secondary)
                }
            }.panelStyle()
        }

        private var encoderSelector: some View {
            Stepper(l.text("Encoder %@", String(command.encoder)), value: $command.encoder, in: 1 ... 16)
        }

        private var latestAttempt: some View {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(l.text("Last test and physical observation"), icon: "eye")
                if let attempt = state.attempts.first {
                    Text(attempt.message.description).font(.headline.monospaced())
                    Text(l.text("Transport: %@", l.text(attempt.delivery.rawValue))).font(.callout)
                    Text(l.text("Operator response: %@", attempt.reportedResponse.map { l.text($0.rawValue) } ?? l.text("Not reported")))
                        .foregroundStyle(attempt.reportedResponse == .matches ? Theme.value : Color.secondary)
                    TextField(l.text("Actual LED, ring pattern, blink period or layer response"), text: $responseNote, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2 ... 5)
                    HStack {
                        ForEach(NonMotorReportedResponse.allCases, id: \.self) { result in
                            Button(l.text(result.rawValue)) { intents.recordNonMotorObservation?(attempt.id, result, responseNote) }
                                .disabled(!state.canRecordObservation)
                        }
                    }
                    if let note = attempt.note {
                        Text(note).font(.caption).textSelection(.enabled)
                    }
                } else {
                    Text(l.text("No nonmotor command sent. Device response remains unknown.")).foregroundStyle(.secondary)
                }
                Text(l.text("Observed input layer: %@", snapshot.hardwareObservation?.inputLayer?.rawValue.uppercased() ?? "—"))
                    .font(.caption.monospaced())
            }.panelStyle()
                .onChange(of: state.attempts.first?.id) { _, _ in responseNote = "" }
        }

        private var history: some View {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(l.text("Nonmotor test history"), icon: "clock.arrow.circlepath")
                Text(l.text("The recording retains every attempt and observation; this list shows the latest 32."))
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(state.attempts) { attempt in
                    HStack {
                        Text(attempt.timestamp.formatted(date: .omitted, time: .standard)).font(.caption.monospaced())
                        Text(attempt.message.description).font(.caption.monospaced())
                        Spacer()
                        Text(l.text(attempt.delivery.rawValue)).font(.caption)
                        Text(attempt.reportedResponse.map { l.text($0.rawValue) } ?? "—").font(.caption)
                    }
                }
            }.panelStyle()
        }
    }
#endif
