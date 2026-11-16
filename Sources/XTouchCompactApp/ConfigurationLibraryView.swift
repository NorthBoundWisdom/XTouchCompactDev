#if os(macOS)
    import SwiftUI
    import XTouchCompactLocalization

    struct ConfigurationLibraryView: View {
        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @EnvironmentObject private var language: LanguageSettings
        @State private var name = ""
        var body: some View {
            let l = language.localizer
            Section(l.text("Configuration library")) {
                TextField(l.text("Configuration name"), text: $name)
                Button(l.text("Save configuration")) { intents.saveLibraryConfiguration?(name) }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text(l.text("Library entries exclude device profiles and runtime values. Loading never recalls motors."))
                    .font(.caption).foregroundStyle(.secondary)
                if let warning = snapshot.libraryWarning {
                    Text(l.text(warning)).foregroundStyle(.orange)
                }
                ForEach(snapshot.libraryEntries) { entry in
                    HStack {
                        Text(entry.name)
                        Spacer()
                        Button(l.text("Load")) { intents.requestLibraryLoad?(entry.id) }
                        Button(l.text("Delete"), role: .destructive) { intents.requestLibraryDelete?(entry.id) }
                    }
                }
            }
            .confirmationDialog(l.text("Confirm configuration library action"), isPresented: Binding(
                get: { snapshot.pendingLibraryAction != nil }, set: {
                    if !$0 {
                        intents.cancelLibraryAction?()
                    }
                }
            ), titleVisibility: .visible) {
                if let request = snapshot.pendingLibraryAction {
                    Button(l.text(request.kind == .load ? "Load" : "Delete"), role: request.kind == .delete ? .destructive : nil) { intents.confirmLibraryAction?() }
                }
                Button(l.text("Cancel"), role: .cancel) { intents.cancelLibraryAction?() }
            } message: {
                if let request = snapshot.pendingLibraryAction {
                    Text(request.name)
                }
            }
        }
    }
#endif
