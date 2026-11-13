#if os(macOS)
    import SwiftUI
    import XTouchCompactLocalization

    @MainActor
    final class LanguageSettings: ObservableObject {
        private let defaults: UserDefaults
        @Published var selection: AppLanguage {
            didSet { defaults.set(selection.rawValue, forKey: "appLanguage") }
        }

        @Published private var systemLanguages = Locale.preferredLanguages
        var localizer: Localizer {
            Localizer(language: selection, preferredLanguages: systemLanguages)
        }

        init(defaults: UserDefaults = .standard) {
            self.defaults = defaults
            selection = AppLanguage(storedValue: defaults.string(forKey: "appLanguage"))
        }

        func refreshSystemLanguage() {
            systemLanguages = Locale.preferredLanguages
        }
    }

    struct LanguageSettingsView: View {
        let snapshot: PanelSnapshot
        let intents: PanelIntents
        @EnvironmentObject private var language: LanguageSettings
        var body: some View {
            let l = language.localizer
            Form {
                Picker(l.text("Language"), selection: $language.selection) {
                    Text(l.text("Follow System")).tag(AppLanguage.system)
                    Text("English").tag(AppLanguage.english)
                    Text("简体中文").tag(AppLanguage.simplifiedChinese)
                    Text("繁體中文").tag(AppLanguage.traditionalChinese)
                }
                ExternalServicesSettings(snapshot: snapshot, intents: intents)
                Text(l.text("Language changes apply immediately and are saved automatically."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped)
            .padding()
            .frame(width: 580)
            .frame(minHeight: 650)
        }
    }
#endif
