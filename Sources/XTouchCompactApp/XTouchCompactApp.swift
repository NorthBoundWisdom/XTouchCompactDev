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
            let languageSettings = LanguageSettings(defaults: defaults)
            _language = StateObject(wrappedValue: languageSettings)
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
                model.loadReferenceArmExample(using: languageSettings.localizer)
            }
            model.startRuntime()
            if observing {
                model.beginHardwareObservation()
            } else if arguments.contains("--hardware-control"), !isolated {
                // Explicit launch choice: allow fresh writes without recalling any motors.
                model.useHardware(true)
                model.enableHardwareWriteback()
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
                        model.flushHardwareValues()
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
                // Parameter value history, beside (not replacing) the system Undo so text fields
                // keep ⌘Z while editing.
                CommandGroup(after: .undoRedo) {
                    Button(language.localizer.text("Undo value change")) { model.undo() }
                        .keyboardShortcut("z", modifiers: [.command, .option])
                        .disabled(!model.session.canUndo)
                    Button(language.localizer.text("Redo value change")) { model.redo() }
                        .keyboardShortcut("z", modifiers: [.command, .option, .shift])
                        .disabled(!model.session.canRedo)
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
