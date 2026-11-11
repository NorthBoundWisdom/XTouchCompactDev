#if os(macOS)
    import SwiftUI

    @main
    @MainActor
    struct XTouchCompactDevApp: App {
        @StateObject private var model: ConsoleModel
        @StateObject private var language: LanguageSettings

        init() {
            let isolated = ProcessInfo.processInfo.arguments.contains("--startup-smoke") || ProcessInfo.processInfo.arguments.contains("--integration-test")
            let root = isolated ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("XTouchCompactConsole")
            let defaults = isolated ? UserDefaults(suiteName: "XTouchCompactDev.tests.\(UUID().uuidString)")! : .standard
            _language = StateObject(wrappedValue: LanguageSettings(defaults: defaults))
            let model = ConsoleModel(startsMIDI: !isolated, storageRoot: root, isolated: isolated)
            model.startRuntime()
            _model = StateObject(wrappedValue: model)
        }

        var body: some Scene {
            WindowGroup {
                ContentView(model: model)
                    .environmentObject(language)
                    .environment(\.locale, Locale(identifier: language.localizer.language.rawValue))
                    .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                        language.refreshSystemLanguage()
                    }
                    .task {
                        let arguments = ProcessInfo.processInfo.arguments
                        if let index = arguments.firstIndex(of: "--snapshot-output"), arguments.indices.contains(index + 1) {
                            do {
                                try await capturePreview(model: model, language: language, path: arguments[index + 1])
                                print("Preview capture complete")
                            } catch { print("Preview capture failed: \(error)"); exit(1) }
                            NSApplication.shared.terminate(nil)
                        }
                        if arguments.contains("--startup-smoke") {
                            try? await Task.sleep(for: .milliseconds(300))
                            print("{\"type\":\"xtouch.native_startup\",\"hardwareAccessed\":false}")
                            fflush(nil)
                            NSApplication.shared.terminate(nil)
                        }
                    }
                    .frame(minWidth: 1200, minHeight: 760)
            }
            .windowStyle(.hiddenTitleBar)
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
                    .environmentObject(model)
                    .environment(\.locale, Locale(identifier: language.localizer.language.rawValue))
            }
        }
    }
#else
    // Permit protocol-only SwiftPM builds/tests on Linux CI without linking AppKit/CoreMIDI.
    import Foundation

    @main
    struct XTouchCompactDevApp {
        static func main() {
            print("The XTouchCompactDev GUI requires macOS 14 or later.")
        }
    }
#endif
