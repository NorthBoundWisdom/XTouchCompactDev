#if os(macOS)
    import SwiftUI
    import XTouchCompactCore

    @main
    enum XTouchLauncher {
        @MainActor static func main() {
            if ProcessInfo.processInfo.arguments.contains("--snapshot-output") {
                PreviewCommand.run()
            } else {
                XTouchCompactDevApp.main()
            }
        }
    }

    @MainActor
    struct XTouchCompactDevApp: App {
        @StateObject private var model: ConsoleModel
        @StateObject private var language: LanguageSettings

        init() {
            let arguments = ProcessInfo.processInfo.arguments
            let observing = arguments.contains("--hardware-observe")
            let isolated = arguments.contains("--startup-smoke") || arguments.contains("--integration-test")
            let root = isolated || observing ? nil : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appendingPathComponent("XTouchCompactConsole")
            let defaults = isolated ? UserDefaults(suiteName: "XTouchCompactDev.tests.\(UUID().uuidString)")! : .standard
            _language = StateObject(wrappedValue: LanguageSettings(defaults: defaults))
            let model = ConsoleModel(startsMIDI: !isolated, storageRoot: root, isolated: isolated)
            var selection = Set<OptionalBusinessPlugin>()
            if arguments.contains("--robot-plugin") {
                selection.insert(.robot)
            }
            if arguments.contains("--chassis-plugin") {
                selection.insert(.chassis)
            }
            if arguments.contains("--output-plugin") {
                selection.insert(.output)
            }
            if !selection.isEmpty {
                model.installOptionalPlugins(selection)
            }
            if arguments.contains("--reference-arm-example") {
                model.loadReferenceArmExample()
            }
            model.startRuntime()
            if observing {
                model.beginHardwareObservation()
            }
            if observing, !isolated, let index = arguments.firstIndex(of: "--capture-path"), arguments.indices.contains(index + 1) {
                model.startCapture(URL(fileURLWithPath: arguments[index + 1]))
            }
            _model = StateObject(wrappedValue: model)
        }

        var body: some Scene {
            WindowGroup {
                ContentView(snapshot: model.panelSnapshot, intents: model.panelIntents)
                    .environmentObject(language)
                    .environment(\.locale, Locale(identifier: language.localizer.language.rawValue))
                    .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
                        language.refreshSystemLanguage()
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                        model.stopCapture()
                    }
                    .task {
                        let arguments = ProcessInfo.processInfo.arguments
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
                LanguageSettingsView(snapshot: model.panelSnapshot, intents: model.panelIntents)
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
        static func main() {
            print("The XTouchCompactDev GUI requires macOS 14 or later.")
        }
    }
#endif
