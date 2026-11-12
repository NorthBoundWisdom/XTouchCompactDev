#if os(macOS)
    import SwiftUI
    import XTouchCompactCore
    import XTouchCompactLocalization

    struct ParameterWorkspace: View {
        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @EnvironmentObject private var language: LanguageSettings
        @State private var draft: SurfaceConfiguration

        init(snapshot: PanelSnapshot, intents: PanelIntents) {
            self.snapshot = snapshot; self.intents = intents
            _draft = State(initialValue: snapshot.configuration)
        }

        @State private var confirmsReset = false
        @State private var target = ""
        @State private var kind = "fader"
        @State private var first = 1
        @State private var last = 1
        @State private var action = "parameter"
        @State private var amount = 1.0
        private var l: Localizer {
            language.localizer
        }

        var body: some View {
            ScrollView {
                VStack(alignment: .leading) {
                    HStack {
                        Button(l.text("Edit configuration")) { draft = snapshot.configuration }
                        Button(l.text("Apply configuration")) { intents.applyConfiguration?(draft) }
                        Menu(l.text("Load preset…")) {
                            Button(l.text("Audio example")) { intents.loadPreset?(.audioExample) }
                            Button(l.text("Neutral preset")) { intents.loadPreset?(.neutral) }
                        }
                    }
                    HStack {
                        Button(l.text("Import configuration…")) { intents.importConfiguration?() }
                        Button(l.text("Export configuration…")) { intents.exportConfiguration?() }
                    }
                    Button(l.text("Reset parameter values…")) { confirmsReset = true }
                        .confirmationDialog(l.text("Reset all parameter values to defaults?"), isPresented: $confirmsReset) {
                            Button(l.text("Reset values"), role: .destructive) { intents.resetParameters?() }
                            Button(l.text("Cancel"), role: .cancel) {}
                        }
                    Text(l.text("Configuration edits preserve values; resetting defaults requires confirmation."))
                        .font(.caption).foregroundStyle(.secondary)
                    Text(l.text("Loading a configuration does not recall motors."))
                        .font(.caption).foregroundStyle(.secondary)
                    Button(l.text("Add parameter")) {
                        draft.parameters.append(ParameterDefinition(id: UUID().uuidString, name: "Parameter"))
                    }
                    ForEach(Array(draft.parameters.indices), id: \.self) { index in
                        let definition = draft.parameters[index]
                        VStack(alignment: .leading) {
                            HStack {
                                // Color tag is edited in the inspector; shown here for orientation.
                                Capsule().fill(definition.color.map(Theme.tag) ?? Color.clear).frame(width: 4, height: 18)
                                TextField(l.text("Name"), text: $draft.parameters[index].name)
                                TextField(l.text("Unit"), text: $draft.parameters[index].unit).frame(width: 55)
                                Toggle(l.text("Agent write"), isOn: $draft.parameters[index].agentWritable)
                            }
                            HStack {
                                labeled(l.text("Group")) { TextField(l.text("Group"), text: $draft.parameters[index].group) }
                                labeled(l.text("Default")) {
                                    TextField(l.text("Default"), value: $draft.parameters[index].defaultValue, format: .number)
                                }
                                Toggle(l.text("Switch"), isOn: $draft.parameters[index].isSwitch)
                            }
                            HStack {
                                labeled(l.text("Minimum")) {
                                    TextField(l.text("Minimum"), value: $draft.parameters[index].minimum, format: .number)
                                }
                                labeled(l.text("Maximum")) {
                                    TextField(l.text("Maximum"), value: $draft.parameters[index].maximum, format: .number)
                                }
                                labeled(l.text("Step")) { TextField(l.text("Step"), value: $draft.parameters[index].step, format: .number) }
                            }
                            if let applied = snapshot.configuration.parameters.first(where: { $0.id == definition.id }),
                               let value = snapshot.parameterValues[definition.id], applied.minimum < applied.maximum
                            {
                                HStack {
                                    Slider(value: Binding(get: { value },
                                                          set: { intents.setParameter?(definition.id, $0) }),
                                           in: applied.minimum ... applied.maximum)
                                        .accessibilityLabel(definition.name)
                                    Text(value.formatted(.number.precision(.fractionLength(0 ... 3))) + (applied.unit.isEmpty ? "" : " " + applied.unit))
                                        .font(.caption.monospaced())
                                        .foregroundStyle(Theme.value)
                                        .frame(minWidth: 56, alignment: .trailing)
                                }
                            }
                        }.padding(8).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    }
                    Divider()
                    Text(l.text("Bulk assignment")).font(.headline)
                    Picker(l.text("Control"), selection: $kind) {
                        Text(l.text("fader")).tag("fader")
                        Text(l.text("encoder")).tag("encoder")
                        Text(l.text("button")).tag("button")
                        Text(l.text("Touch")).tag("touch")
                        Text(l.text("Encoder push")).tag("push")
                        Text(l.text("表情踏板")).tag("expression")
                        Text(l.text("脚踏开关")).tag("footswitch")
                    }
                    Stepper(l.text("First: %@", String(first)), value: $first, in: 1 ... 39)
                    Stepper(l.text("Last: %@", String(last)), value: $last, in: 1 ... 39)
                    Picker(l.text("Action"), selection: $action) {
                        ForEach(["parameter", "agent", "step", "set", "cycle", "resetGroup"], id: \.self) { Text(l.text($0)).tag($0) }
                    }
                    Picker(l.text("Parameter"), selection: $target) {
                        Text("—").tag("")
                        ForEach(draft.parameters) { Text($0.name).tag($0.id) }
                    }
                    TextField(l.text("Value / Agent slot"), value: $amount, format: .number)
                    Button(l.text("Assign range on current layer")) { assign() }
                }
            }
            .preferredColorScheme(.dark)
            .background(Theme.background)
            .onChange(of: snapshot.configuration) { _, configuration in draft = configuration }
            .confirmationDialog(l.text("Reset all parameter values to defaults?"), isPresented: Binding(
                get: { snapshot.pendingPreset != nil },
                set: {
                    if !$0 {
                        intents.cancelLoadPreset?()
                    }
                }
            )) {
                Button(l.text("Reset values"), role: .destructive) { intents.confirmLoadPreset?() }
                Button(l.text("Cancel"), role: .cancel) { intents.cancelLoadPreset?() }
            }
        }

        /// A caption above a field: filled text fields no longer show their placeholder.
        private func labeled(_ title: String, @ViewBuilder content: () -> some View) -> some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                content().labelsHidden()
            }
        }

        private func assign() {
            guard first <= last else { return }
            let selected: ParameterAction
            switch action {
            case "agent": guard amount.isFinite, (1 ... 8).contains(amount) else { return }; selected = .agent(Int(amount))
            case "step": selected = .step(target, amount)
            case "set": selected = .set(target, amount)
            case "cycle": selected = .cycle(target, [0, amount])
            case "resetGroup": selected = .resetGroup(draft.parameters.first { $0.id == target }?.group ?? "General")
            default: selected = .parameter(target)
            }
            for index in first ... last {
                let control: CompactControl = switch kind {
                case "fader": .fader(index)
                case "encoder": .encoder(index)
                case "touch": .faderTouch(index)
                case "push": .encoderPush(index)
                case "expression": .expression
                case "footswitch": .footswitch
                default: .button(index)
                }
                draft.assignments.removeAll { $0.control == control && $0.layer == snapshot.layer }
                draft.assignments.append(.init(control: control, layer: snapshot.layer, action: selected))
            }
            intents.applyConfiguration?(draft)
        }
    }
#endif
