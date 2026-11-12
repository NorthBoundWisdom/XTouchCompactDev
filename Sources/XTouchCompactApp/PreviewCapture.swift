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
        case "startup-readings", "startup-readings-live", "startup-readings-empty":
            width = 1600; height = 1000
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("XTouch-readings-preview-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            var workspace = SavedWorkspace(configuration: .neutral, profile: .init())
            if scene != "startup-readings-empty" {
                var values = HardwareValueCache(inputID: 1, transmitChannel: 0)
                let map = try FactoryStandardMap()
                for message: MIDIMessage in [.controlChange(channel: 0, number: 28, value: 8),
                                             .controlChange(channel: 0, number: 37, value: 6),
                                             .controlChange(channel: 0, number: 38, value: 10),
                                             .controlChange(channel: 0, number: 45, value: 18),
                                             .controlChange(channel: 0, number: 46, value: 22)]
                {
                    if let input = map.decode(message) {
                        values.record(input, at: Date(timeIntervalSince1970: 1_794_405_600))
                    }
                }
                workspace.hardwareValues = values
            }
            try ProtectedWorkspaceStore(directory: root).save(workspace)
            let service = ObservationPreviewService()
            let preview = ConsoleModel(startsMIDI: false, midi: service, storageRoot: root, isolated: true)
            let endpoint = CompactMIDIEndpoint(id: 1, name: "Isolated preview fixture")
            service.onConnection?(CompactMIDIConnection(connectedInput: endpoint, connectedOutput: endpoint))
            preview.useHardware(true)
            if scene == "startup-readings-live" {
                service.onMessages?([.controlChange(channel: 0, number: 28, value: 8)])
            }
            content = AnyView(ContentView(snapshot: preview.panelSnapshot, intents: preview.panelIntents))
        case "organization":
            // Synthetic names, tags, a link and a scene; isolated, nothing is persisted.
            width = 1600; height = 1100
            for (index, name, color, group) in [(1, "Kick", ParameterColor.red, "Drums"), (2, "Snare", .red, "Drums"),
                                                (3, "Hats", .orange, "Drums"), (4, "Bass", .blue, "Low end"),
                                                (5, "Keys", .green, "Music"), (6, "Pad", .green, "Music")]
            {
                model.renameControl(.fader(index), name: name)
                model.setControlColor(.fader(index), color: color)
                model.setControlGroup(.fader(index), group: group)
            }
            model.renameControl(.encoder(1), name: "Reverb")
            model.setControlColor(.encoder(1), color: .purple)
            model.saveLink(ParameterLink(id: "drums", name: "Drums", leader: "a.Fader.1", members: ["a.Fader.2", "a.Fader.3"]))
            for (index, value) in [(1, 90.0), (4, 70), (5, 50), (6, 40)] {
                model.setParameter("a.Fader.\(index)", value: value)
            }
            model.captureScene(name: "Verse")
            model.highlightedGroup = "Drums"
            model.moveExpression(72)
            content = AnyView(ContentView(snapshot: model.panelSnapshot, intents: model.panelIntents,
                                          selection: .fader(2), initialTab: .organize))
        // N5 reference renders: the expected state for each mouse acceptance row, built with the
        // same model calls the UI uses. Compare these with the live app; they are not acceptance.
        case "n5-touch":
            width = 1600; height = 1000
            model.setParameter("a.Fader.1", value: 40)
            model.touchFader(1, isTouched: true)
            model.setParameter("a.Fader.1", value: 110) // A software write while held: deferred.
            content = AnyView(ContentView(snapshot: model.panelSnapshot, intents: model.panelIntents, selection: .fader(1)))
        case "n5-layer":
            width = 1600; height = 1000
            // Mock physical layer B while the host stays on A: the mismatch warning and motor gate.
            model.setMockPhysicalLayerForPreview(.b)
            model.touchFader(2, isTouched: true)
            model.touchFader(2, isTouched: false)
            content = AnyView(ContentView(snapshot: model.panelSnapshot, intents: model.panelIntents,
                                          selection: .fader(2), initialTab: .connection))
        case "n5-osc":
            width = 1600; height = 1000
            model.setOSCEnabled(true) // No trusted actual/heartbeat: refused with a visible notice.
            content = AnyView(ContentView(snapshot: model.panelSnapshot, intents: model.panelIntents))
        case "n5-mcp":
            width = 650; height = 1100
            model.mcpWritesAllowed = true
            content = AnyView(LanguageSettingsView(snapshot: model.panelSnapshot, intents: model.panelIntents))
        case "organize-page":
            // The Organize workspace alone, with synthetic links and scenes.
            width = 760; height = 760
            model.renameControl(.fader(1), name: "Kick")
            model.setControlColor(.fader(1), color: .red)
            model.setControlGroup(.fader(1), group: "Drums")
            model.renameControl(.fader(2), name: "Snare")
            model.setControlGroup(.fader(2), group: "Drums")
            model.saveLink(ParameterLink(id: "drums", name: "Drums", leader: "a.Fader.1", members: ["a.Fader.2"]))
            model.setParameter("a.Fader.1", value: 80)
            model.captureScene(name: "Verse")
            model.captureScene(name: "Chorus")
            content = AnyView(OrganizeWorkspace(snapshot: model.panelSnapshot, intents: model.panelIntents).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Theme.background))
        case "connection-page":
            // The Connection page alone, in the mock, with the applied profile shown.
            width = 620; height = 640
            content = AnyView(ConnectionSettingsView(snapshot: model.panelSnapshot, intents: model.panelIntents).padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).background(Theme.background))
        case "organization-values":
            // The Values tab with the same synthetic organization data.
            width = 1600; height = 1400
            for (index, name, color, group) in [(1, "Kick", ParameterColor.red, "Drums"), (2, "Snare", .red, "Drums"),
                                                (4, "Bass", .blue, "Low end")]
            {
                model.renameControl(.fader(index), name: name)
                model.setControlColor(.fader(index), color: color)
                model.setControlGroup(.fader(index), group: group)
            }
            model.saveLink(ParameterLink(id: "drums", name: "Drums", leader: "a.Fader.1", members: ["a.Fader.2"]))
            model.setParameter("a.Fader.1", value: 80)
            model.highlightedGroup = "Drums"
            content = AnyView(ContentView(snapshot: model.panelSnapshot, intents: model.panelIntents, selection: .fader(1)))
        case "encoder-rings":
            width = 1600; height = 1000
            for (index, value) in [(1, 6), (2, 10), (3, 11), (4, 39), (9, 18), (10, 22), (11, 32), (12, 43), (13, 64), (14, 96), (15, 127), (16, 127)] {
                model.encoderChanged(index, value: Double(value))
            }
            content = AnyView(ContentView(snapshot: model.panelSnapshot, intents: model.panelIntents))
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
