#if os(macOS)
    import SwiftUI
    import XTouchCompactCore
    import XTouchCompactLocalization

    /// Groups (panel highlight), fader links and scenes. Everything here edits configuration or
    /// host intent; scene recall never drives motors, which stay behind the explicit recall.
    struct OrganizeWorkspace: View {
        @EnvironmentObject private var language: LanguageSettings
        private var l: Localizer {
            language.localizer
        }

        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @State private var sceneName = ""
        @State private var linkName = ""
        @State private var leader = ""
        @State private var members: Set<String> = []
        /// ID of the link loaded into the form, or nil while composing a new one.
        @State private var editingLink: String?
        @State private var renamingScene: String?
        @State private var sceneRename = ""

        private var parameters: [XTouchCompactCore.ParameterDefinition] {
            snapshot.configuration.parameters
        }

        private var groups: [(name: String, parameters: [XTouchCompactCore.ParameterDefinition])] {
            Dictionary(grouping: parameters, by: \.group).map { ($0.key, $0.value) }.sorted { $0.name < $1.name }
        }

        private func name(_ id: String) -> String {
            parameters.first { $0.id == id }?.name ?? id
        }

        var body: some View {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button { intents.undo?() } label: { Label(l.text("Undo"), systemImage: "arrow.uturn.backward") }
                        .disabled(!snapshot.canUndo)
                    Button { intents.redo?() } label: { Label(l.text("Redo"), systemImage: "arrow.uturn.forward") }
                        .disabled(!snapshot.canRedo)
                    Text(l.text("Undo restores values like any software write: touched faders wait for release."))
                        .font(.caption).foregroundStyle(.secondary)
                }
                section(l.text("Groups")) {
                    Text(l.text("Highlight a group on the panel. Set a control's group in the inspector."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(groups, id: \.name) { group in
                        let isOn = snapshot.highlightedGroup == group.name
                        Button { intents.highlightGroup?(isOn ? nil : group.name) } label: {
                            HStack {
                                Image(systemName: isOn ? "eye.fill" : "eye")
                                Text(group.name).bold()
                                Text(group.parameters.map(\.name).prefix(6).joined(separator: ", "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Spacer()
                                ForEach(Array(Set(group.parameters.compactMap(\.color))).sorted { $0.rawValue < $1.rawValue }, id: \.self) {
                                    Circle().fill(Theme.tag($0)).frame(width: 8, height: 8)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                section(l.text("Fader links")) {
                    Text(l.text("Moving the leader moves each member by the same fraction of its range. Touched faders wait; Agent motor permission still applies."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(snapshot.configuration.links ?? []) { link in
                        HStack {
                            Text("⛓ " + link.name).bold()
                            Text(name(link.leader) + " → " + link.members.map(name).joined(separator: ", "))
                                .font(.caption).lineLimit(1)
                            Spacer()
                            Button { load(link) } label: { Image(systemName: "pencil") }
                                .buttonStyle(.plain).help(l.text("Edit link"))
                            Button(role: .destructive) {
                                intents.deleteLink?(link.id)
                                if editingLink == link.id {
                                    clearLinkForm()
                                }
                            } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).help(l.text("Delete link"))
                        }
                    }
                    HStack {
                        TextField(l.text("Link name"), text: $linkName).frame(width: 120)
                        Picker(l.text("Leader"), selection: $leader) {
                            Text("—").tag("")
                            ForEach(parameters) { Text($0.name + " · " + $0.id).tag($0.id) }
                        }
                    }
                    Menu(members.isEmpty ? l.text("Choose members") : members.map(name).sorted().joined(separator: ", ")) {
                        ForEach(parameters.filter { $0.id != leader }) { parameter in
                            Button { toggle(parameter.id) } label: {
                                Label(parameter.name + " · " + parameter.id, systemImage: members.contains(parameter.id) ? "checkmark" : "")
                            }
                        }
                    }
                    HStack {
                        Button(l.text(editingLink == nil ? "Add link" : "Save link")) {
                            intents.saveLink?(ParameterLink(id: editingLink ?? UUID().uuidString,
                                                            name: linkName.trimmingCharacters(in: .whitespaces),
                                                            leader: leader, members: members.subtracting([leader]).sorted()))
                            clearLinkForm()
                        }
                        .disabled(linkName.trimmingCharacters(in: .whitespaces).isEmpty || leader.isEmpty
                            || members.subtracting([leader]).isEmpty)
                        if editingLink != nil {
                            Button(l.text("Cancel"), action: clearLinkForm)
                        }
                    }
                }
                section(l.text("Scenes")) {
                    Text(l.text("A scene stores every parameter value. Recall updates targets, rings and LEDs; faders move only with 电机归位."))
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(snapshot.configuration.scenes ?? []) { scene in
                        HStack {
                            if renamingScene == scene.id {
                                TextField(l.text("Scene name"), text: $sceneRename)
                                    .frame(maxWidth: 180)
                                    .onSubmit { commitSceneRename(scene.id) }
                                Button(l.text("Rename")) { commitSceneRename(scene.id) }
                                    .disabled(sceneRename.trimmingCharacters(in: .whitespaces).isEmpty)
                                Button(l.text("Cancel")) { renamingScene = nil }
                            } else {
                                Text(scene.name).bold()
                                Text(l.text("%@ values", String(scene.values.count))).font(.caption).foregroundStyle(.secondary)
                                Button { renamingScene = scene.id; sceneRename = scene.name } label: { Image(systemName: "pencil") }
                                    .buttonStyle(.plain).help(l.text("Rename scene"))
                            }
                            Spacer()
                            Button(l.text("Recall")) { intents.recallScene?(scene.id) }
                            Button(l.text("Update")) { intents.captureScene?(scene.name) }
                                .help(l.text("Replace this scene with the current values"))
                            Button(role: .destructive) { intents.deleteScene?(scene.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.plain).help(l.text("Delete scene"))
                        }
                    }
                    HStack {
                        TextField(l.text("Scene name"), text: $sceneName)
                            .onSubmit(saveScene)
                        Button(l.text("Save current values"), action: saveScene)
                            .disabled(sceneName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
        }

        private func saveScene() {
            let trimmed = sceneName.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            intents.captureScene?(trimmed)
            sceneName = ""
        }

        private func load(_ link: ParameterLink) {
            editingLink = link.id; linkName = link.name; leader = link.leader; members = Set(link.members)
        }

        private func clearLinkForm() {
            editingLink = nil; linkName = ""; leader = ""; members = []
        }

        private func commitSceneRename(_ id: String) {
            intents.renameScene?(id, sceneRename)
            renamingScene = nil
        }

        private func toggle(_ id: String) {
            if members.contains(id) {
                members.remove(id)
            } else {
                members.insert(id)
            }
        }

        private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline.bold())
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
        }
    }
#endif
