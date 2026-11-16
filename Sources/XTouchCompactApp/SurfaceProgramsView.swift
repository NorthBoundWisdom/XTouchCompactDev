#if os(macOS)
    import SwiftUI
    import XTouchCompactCore
    import XTouchCompactLocalization

    struct SurfaceProgramsView: View {
        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @EnvironmentObject private var language: LanguageSettings
        @State private var name = ""
        @State private var kind = "set"
        @State private var target = ""
        @State private var amount = 0.0
        @State private var actions: [ParameterMutation] = []
        var body: some View {
            let l = language.localizer
            GroupBox(l.text("Macros")) {
                VStack(alignment: .leading) {
                    TextField(l.text("Macro name"), text: $name)
                        .accessibilityIdentifier("macros.macroName")
                    HStack {
                        Picker(l.text("Action"), selection: $kind) {
                            ForEach(["set", "step", "toggle", "resetGroup"], id: \.self) { Text(l.text($0)).tag($0) }
                        }.accessibilityIdentifier("macros.action")
                        Picker(l.text("Parameter"), selection: $target) {
                            Text("—").tag("")
                            ForEach(snapshot.configuration.parameters) { Text($0.name).tag($0.id) }
                        }.accessibilityIdentifier("macros.parameter")
                        TextField(l.text("Value"), value: $amount, format: .number)
                            .accessibilityIdentifier("macros.value")
                        Button(l.text("Add step")) { addStep() }.accessibilityIdentifier("macros.addStep").disabled(actions.count >= 64 || target.isEmpty || !amount.isFinite || (kind == "step" && amount == 0))
                    }
                    ForEach(Array(actions.enumerated()), id: \.offset) { index, action in
                        HStack {
                            Text("\(index + 1). " + label(action, l: l)).font(.caption.monospaced())
                            Spacer()
                            Button(l.text("Remove")) { actions.remove(at: index) }.accessibilityIdentifier("macros.remove.\(index)")
                        }
                    }
                    Button(l.text("Save macro")) { intents.saveMacro?(.init(name: name, actions: actions)) }.accessibilityIdentifier("macros.saveMacro")
                        .disabled(actions.isEmpty || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Text(l.text("Up to 64 steps, executed in order. Rejected steps are reported; later steps continue. One macro is one undo."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(snapshot.configuration.macros ?? []) { macro in
                        HStack {
                            Text(macro.name)
                            Spacer()
                            Button(l.text("Run macro")) { intents.runMacro?(macro.id) }.accessibilityIdentifier("macros.runMacro.\(macro.id)")
                            Button(l.text("Delete"), role: .destructive) { intents.deleteMacro?(macro.id) }.accessibilityIdentifier("macros.delete.\(macro.id)")
                        }
                    }
                    if let result = snapshot.lastMacroExecution {
                        Text(result.name).font(.headline)
                        ForEach(result.steps) { step in
                            Text(l.text("Step %@: %@", String(step.id), l.text(step.outcome.rawValue)))
                                .accessibilityIdentifier("macros.result.\(step.id)")
                                .accessibilityValue(l.text(step.outcome.rawValue))
                                .font(.caption)
                        }
                    }
                }
            }
        }

        private func addStep() {
            switch kind {
            case "step": actions.append(.step(target, amount))
            case "toggle": actions.append(.toggle(target))
            case "resetGroup": actions.append(.resetGroup(snapshot.configuration.parameters.first { $0.id == target }?.group ?? ""))
            default: actions.append(.set(target, amount))
            }
        }

        private func label(_ action: ParameterMutation, l: Localizer) -> String {
            switch action {
            case let .set(id, value): l.text("set") + " \(id) = \(value)"
            case let .step(id, value): l.text("step") + " \(id) + \(value)"
            case let .toggle(id): l.text("toggle") + " " + id
            case let .resetGroup(group): l.text("resetGroup") + " " + group
            }
        }
    }
#endif
