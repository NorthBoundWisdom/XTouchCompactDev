#if os(macOS)
import SwiftUI

@main
@MainActor
struct XTouchCompactDevApp: App {
    @StateObject private var model = ConsoleModel()
    @StateObject private var language = LanguageSettings()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .environmentObject(language)
                .environment(\.locale, Locale(identifier: language.localizer.language.rawValue))
                .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                    language.refreshSystemLanguage()
                }
                .frame(minWidth: 1_200, minHeight: 760)
        }
        .defaultSize(width: 1260, height: 920)
        .commands {
            CommandGroup(replacing: .appSettings) {
                SettingsLink { Text(language.localizer.text("Settings") + "…") }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
        Settings {
            LanguageSettingsView()
                .environmentObject(language)
                .environment(\.locale, Locale(identifier: language.localizer.language.rawValue))
        }
    }
}
#else
// Permit protocol-only SwiftPM builds/tests on Linux CI without linking AppKit/CoreMIDI.
import Foundation
@main
struct XTouchCompactDevApp {
    static func main() { print("The XTouchCompactDev GUI requires macOS 14 or later.") }
}
#endif
