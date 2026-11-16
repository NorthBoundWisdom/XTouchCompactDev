#if os(macOS)
    import AppKit
    import Combine
    import Foundation
    import SwiftUI
    import XTouchCompactCore

    @MainActor enum OffscreenIntegrationCommand {
        static func run() -> Never {
            #if DEBUG
                do {
                    let arguments = ProcessInfo.processInfo.arguments
                    func option(_ name: String) -> String? {
                        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
                        return arguments[index + 1]
                    }
                    guard arguments.contains("--integration-test"), arguments.contains("--ui-test-server"),
                          !arguments.contains("--hardware-control"), !arguments.contains("--hardware-observe"),
                          let sessionID = option("--ui-session-id"), UUID(uuidString: sessionID) != nil,
                          let path = ProcessInfo.processInfo.environment["XTOUCH_UI_DATA_DIR"],
                          let token = ProcessInfo.processInfo.environment["XTOUCH_UI_TOKEN"], !token.isEmpty,
                          !token.contains("\r"), !token.contains("\n") else { throw CocoaError(.featureUnsupported) }
                    let root = URL(fileURLWithPath: path)
                    guard try root.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]).isDirectory == true,
                          try root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw CocoaError(.fileReadNoSuchFile) }
                    let owner = try JSONSerialization.jsonObject(with: Data(contentsOf: root.appendingPathComponent("ui-owner.json"))) as? [String: Any]
                    guard owner?["parent_pid"] as? Int == Int(getppid()), owner?["session"] as? String == sessionID else { throw CocoaError(.featureUnsupported) }
                    let app = NSApplication.shared
                    try OffscreenPresentation.install()
                    UserDefaults.standard.setVolatileDomain(["ApplePersistenceIgnoreState": true], forName: UserDefaults.argumentDomain)
                    let context = try OffscreenContext(root: root, token: token, sessionID: sessionID,
                                                       fixture: option("--capture-fixture"), example: arguments.contains("--reference-arm-example"),
                                                       program: arguments.contains("--program-fixture"), library: arguments.contains("--library-fixture"), organize: arguments.contains("--organize-fixture"))
                    withExtendedLifetime(context) { app.run() }
                    exit(0)
                } catch {
                    FileHandle.standardError.write(Data("Offscreen UI acceptance requires a Debug isolated owned session, temporary directory and memory credential.\n".utf8))
                    exit(2)
                }
            #else
                FileHandle.standardError.write(Data("Offscreen acceptance is available only in Debug integration mode.\n".utf8))
                exit(2)
            #endif
        }
    }

    @MainActor private final class OffscreenContext {
        let model: ConsoleModel
        let language: LanguageSettings
        let window: OffscreenInteractionWindow
        let server = LocalMCPServer()
        private let root: URL
        private let sessionID: String
        private var subscription: AnyCancellable?
        private var termination: DispatchSourceSignal?

        init(root: URL, token: String, sessionID: String, fixture: String?, example: Bool, program: Bool, library: Bool, organize: Bool) throws {
            self.root = root; self.sessionID = sessionID
            // Shared reference clock is injected; no wall-time sleeps advance the model.
            let clock = UIClock()
            let replayGate = UIReplayGate()
            model = ConsoleModel(startsMIDI: false, now: { Date(timeIntervalSince1970: clock.time) }, storageRoot: root, isolated: true, mcpPort: 0, offlineReplayYield: { await replayGate.suspend() })
            let defaults = UserDefaults(suiteName: "XTouchCompactDev.UI.\(sessionID)")!
            defaults.setVolatileDomain(["appLanguage": "en"], forName: UserDefaults.argumentDomain)
            language = LanguageSettings(defaults: defaults)
            window = OffscreenInteractionWindow(contentRect: NSRect(x: -30000, y: -30000, width: 1800, height: 1400),
                                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.hidesOnDeactivate = false
            window.becomesKeyOnlyIfNeeded = true
            window.appearance = NSAppearance(named: .darkAqua)
            window.title = "XTouch owned offscreen acceptance"
            OffscreenPresentation.conceal(window)
            model.integrationUIActive = true
            if example {
                model.loadReferenceArmExample(using: language.localizer)
            }
            if library {
                model.saveLibraryConfiguration(name: "UI seed")
            }
            if program {
                model.saveMacro(.init(id: "ui-macro", name: "UI macro", actions: [.set("a.Fader.1", 40), .step("a.Fader.1", 10)]))
            }
            if organize {
                model.setControlGroup(.fader(1), group: "Pair"); model.setControlGroup(.fader(2), group: "Pair")
                model.saveLink(.init(id: "ui-link", name: "UI pair", leader: "a.Fader.1", members: ["a.Fader.2"]))
                model.captureScene(name: "Quiet")
            }
            if let fixture {
                guard ["xtouch-sample.jsonl", "bcr-sample.jsonl", "xtouch-incomplete.jsonl", "xtouch-long.jsonl"].contains(fixture) else { throw CocoaError(.fileReadUnsupportedScheme) }
                let source = root.appendingPathComponent(fixture)
                try model.importOfflineCapture(data: Data(contentsOf: source), name: fixture)
            }
            model.integrationAdvanceAction = { [weak model] in clock.time += 3; replayGate.resume(); model?.advanceAgents() }
            model.integrationCaptureAction = { [weak self] in self?.capture() }
            updateView()
            subscription = model.objectWillChange.sink { [weak self] _ in
                DispatchQueue.main.async { self?.updateView() }
            }
            server.handler = { [weak self] request in
                guard let self, request["method"] as? String == "tools/call",
                      let parameters = request["params"] as? [String: Any], parameters["name"] as? String == "integration_read_state" else { throw MCPError.denied }
                var result = model.readIntegrationState()
                result["isolation"] = ["mockOnly": !model.hardwareMode,
                                       "active": NSApp.isActive,
                                       "frontmostPID": NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1, "allTransparent": NSApp.windows.allSatisfy { $0.alphaValue == 0 && $0.ignoresMouseEvents },
                                       "hasKeyWindow": NSApp.windows.contains { $0.isKeyWindow || $0.isMainWindow },
                                       "suppressedActivations": OffscreenPresentation.suppressedActivations]
                return result
            }
            server.onReady = { port in
                let marker: [String: Any] = ["type": "xtouch.ui_test_ready", "pid": ProcessInfo.processInfo.processIdentifier,
                                             "session": sessionID, "url": "http://127.0.0.1:\(port)/mcp"]
                if let data = try? JSONSerialization.data(withJSONObject: marker) {
                    FileHandle.standardOutput.write(data + Data([10]))
                }
            }
            try server.start(port: 0, token: token)
            window.orderBack(nil)
            signal(SIGTERM, SIG_IGN)
            termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
            termination?.setEventHandler { [weak self] in
                self?.model.flushHardwareValues(); self?.server.stop(); NSApplication.shared.terminate(nil)
            }
            termination?.resume()
        }

        private func updateView() {
            let view = OffscreenAcceptanceView(snapshot: model.panelSnapshot, intents: model.panelIntents)
                .environmentObject(language).environment(\.locale, Locale(identifier: "en"))
            if let host = window.contentView as? NSHostingView<AnyView> {
                host.rootView = AnyView(view)
            } else {
                window.contentView = NSHostingView(rootView: AnyView(view))
            }
            window.contentView?.frame = NSRect(x: 0, y: 0, width: 1800, height: 1400)
            OffscreenPresentation.conceal(window)
        }

        private func capture() {
            guard let view = window.contentView,
                  let image = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.layoutSubtreeIfNeeded()
            view.cacheDisplay(in: view.bounds, to: image)
            do {
                try image.representation(using: .png, properties: [:])?.write(to: root.appendingPathComponent("owned-view.png"), options: .atomic)
                model.integrationCaptureCount += 1
            } catch { model.serviceError(error) }
        }

        @MainActor private final class UIClock { var time: TimeInterval = 100 }
        @MainActor private final class UIReplayGate {
            private var waiting: CheckedContinuation<Void, Never>?
            func suspend() async {
                await withCheckedContinuation { waiting = $0 }
            }

            func resume() {
                waiting?.resume(); waiting = nil
            }
        }
    }
#endif
