#if os(macOS)
    import AppKit
    import SwiftUI
    import XTouchCompactCore

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
        case "nonmotor-tests", "nonmotor-armed", "nonmotor-result":
            width = 1260; height = 1160
            let service = ObservationPreviewService()
            let preview = ConsoleModel(startsMIDI: false, midi: service, isolated: true,
                                       evidenceWriterFactory: { _ in PreviewEvidenceWriter() })
            let endpoint = CompactMIDIEndpoint(id: 1, name: "Isolated preview fixture")
            service.onConnection?(CompactMIDIConnection(connectedInput: endpoint, connectedOutput: endpoint))
            preview.beginHardwareObservation()
            preview.startCapture(URL(fileURLWithPath: "/preview-not-written.jsonl"))
            if scene != "nonmotor-tests" {
                preview.armNonMotorTests(.init(standardModeConfirmed: true, stage1Reviewed: true,
                                               stage1Evidence: "SYNTHETIC PREVIEW · not hardware evidence", firmware: "preview fixture",
                                               receiveChannel: 5, receiveChannelEvidence: "SYNTHETIC PREVIEW · independent RX fixture"))
                preview.previewNonMotorTest(.button(1, .off, .manual), receiveChannel: 5)
                if scene == "nonmotor-result" {
                    service.acceptsNonMotorSimulation = true
                    preview.performNonMotorTest(.button(1, .off, .manual))
                    if let attempt = preview.nonMotorTests.attempts.first {
                        preview.recordNonMotorObservation(attempt.id, result: .differs, note: "SYNTHETIC PREVIEW · simulated observation only")
                    }
                }
            }
            var snapshot = preview.panelSnapshot
            snapshot.hardwareObservation?.isPreview = true
            content = AnyView(ContentView(snapshot: snapshot, intents: preview.panelIntents))
        case "observation", "observation-waiting", "observation-release", "observation-review":
            width = 1260; height = 980
            let service = ObservationPreviewService()
            let preview = ConsoleModel(startsMIDI: false, midi: service, isolated: true)
            preview.beginHardwareObservation()
            if scene != "observation-waiting" {
                service.onMessages?([
                    .controlChange(channel: 0, number: 1, value: 73),
                    .controlChange(channel: 0, number: 12, value: 91),
                    .noteOn(channel: 0, number: 16, velocity: 127),
                    .noteOff(channel: 0, number: 16, velocity: 0),
                    .controlChange(channel: 0, number: 101, value: scene == "observation-release" ? 0 : 127),
                ])
            }
            if scene == "observation-review" {
                service.onMessages?([
                    .controlChange(channel: 0, number: 1, value: 0),
                    .controlChange(channel: 0, number: 1, value: 127),
                    .controlChange(channel: 0, number: 101, value: 0),
                    .controlChange(channel: 0, number: 101, value: 127),
                    .controlChange(channel: 0, number: 37, value: 42),
                    .controlChange(channel: 0, number: 111, value: 0),
                ])
            }
            var snapshot = preview.panelSnapshot
            snapshot.hardwareObservation?.isPreview = true
            content = AnyView(ContentView(snapshot: snapshot, intents: preview.panelIntents))
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

    private final class PreviewEvidenceWriter: EvidenceWriting {
        func write(_: Data) throws {}
        func synchronize() throws {}
        func close() throws {}
    }

    /// Isolated, labeled screenshots never connect to or send messages to a device.
    @MainActor private final class ObservationPreviewService: MIDIService {
        var acceptsNonMotorSimulation = false
        var onMessages: (([XTouchCompactCore.MIDIMessage]) -> Void)?
        var onConnection: ((CompactMIDIConnection) -> Void)?
        func start() throws {}
        func select(inputID _: Int32?, outputID _: Int32?) {}
        func send(_: XTouchCompactCore.MIDIMessage) throws {
            preconditionFailure("Preview attempted MIDI output")
        }

        func sendPinned(_ message: MIDIMessage, inputID: Int32, outputID: Int32, generation: UInt64) throws {
            precondition(acceptsNonMotorSimulation && inputID == 1 && outputID == 1 && generation == 0 &&
                NonMotorTestCommand.isNonMotorFeedback(message, receiveChannel: 5), "Preview attempted invalid MIDI output")
            // This isolated fixture has no CoreMIDI transport or physical port.
        }
    }
#endif
