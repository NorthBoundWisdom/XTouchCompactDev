#if os(macOS)
    import AppKit
    import SwiftUI

    /// The snapshot command starts from AppKit launch, independent of a SwiftUI window's
    /// appearance/task lifecycle. No visible window, CoreMIDI, user defaults or Keychain.
    @MainActor enum PreviewCommand {
        static func run() {
            let arguments = ProcessInfo.processInfo.arguments
            guard arguments.contains("--integration-test"),
                  let index = arguments.firstIndex(of: "--snapshot-output"), arguments.indices.contains(index + 1)
            else {
                print("Snapshot output requires --integration-test and a destination.")
                exit(2)
            }
            let application = NSApplication.shared
            let delegate = PreviewDelegate(path: arguments[index + 1])
            application.setActivationPolicy(.prohibited)
            application.delegate = delegate
            withExtendedLifetime(delegate) { application.run() }
        }
    }

    @MainActor private final class PreviewDelegate: NSObject, NSApplicationDelegate {
        let path: String
        init(path: String) {
            self.path = path
        }

        func applicationDidFinishLaunching(_: Notification) {
            print("Preview: AppKit launched"); fflush(nil)
            Task { @MainActor in
                let defaults = UserDefaults(suiteName: "XTouchCompactDev.preview.\(UUID().uuidString)")!
                let language = LanguageSettings(defaults: defaults)
                let model = ConsoleModel(startsMIDI: false, isolated: true)
                do {
                    try await capturePreview(model: model, language: language, path: path)
                    print("Preview capture complete"); fflush(nil)
                    NSApplication.shared.terminate(nil)
                } catch {
                    print("Preview capture failed: \(error)"); fflush(nil); exit(1)
                }
            }
        }
    }

    /// Render an app-owned offscreen hosting view, never the desktop or another application.
    @MainActor func capturePreview(model: ConsoleModel, language: LanguageSettings, path: String) async throws {
        let arguments = ProcessInfo.processInfo.arguments
        let scene = arguments.firstIndex(of: "--snapshot-scene").flatMap { arguments.indices.contains($0 + 1) ? arguments[$0 + 1] : nil } ?? "console"
        let content: AnyView
        let width: CGFloat
        let height: CGFloat
        switch scene {
        case "settings":
            width = 650; height = 760
            content = AnyView(LanguageSettingsView(snapshot: model.panelSnapshot, intents: model.panelIntents))
        case "parameters":
            width = 700; height = 1000
            content = AnyView(ParameterWorkspace(snapshot: model.panelSnapshot, intents: model.panelIntents).padding())
        default:
            width = 1600; height = 1000
            content = AnyView(ContentView(snapshot: model.panelSnapshot, intents: model.panelIntents))
        }
        let rendered = content.environmentObject(language)
            .environment(\.locale, Locale(identifier: language.localizer.language.rawValue))
            .environment(\.colorScheme, .dark)
            .frame(width: width, height: height)
        print("Preview: creating hosting view (\(scene))"); fflush(nil)
        let host = NSHostingView(rootView: rendered)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        print("Preview: initial layout complete"); fflush(nil)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        print("Preview: caching display"); fflush(nil)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw CocoaError(.fileWriteUnknown) }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance {
            host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw CocoaError(.fileWriteUnknown) }
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try png.write(to: url, options: .atomic)
        window.contentView = nil
    }
#endif
