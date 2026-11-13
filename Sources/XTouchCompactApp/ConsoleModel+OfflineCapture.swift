#if os(macOS)
    import AppKit
    import Foundation
    import UniformTypeIdentifiers
    import XTouchCompactCore
    import XTouchCompactLocalization

    extension ConsoleModel {
        func chooseOfflineCapture() {
            pauseOfflineReplay()
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .data, .json]
            panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
            if panel.runModal() == .OK, let url = panel.url {
                loadOfflineCapture(url)
            }
        }

        func loadOfflineCapture(_ url: URL) {
            pauseOfflineReplay()
            offlineImportTask?.cancel()
            let generation = UUID(); offlineGeneration = generation
            offlineCaptureState.isLoading = true; offlineCaptureState.failure = nil
            offlineImportTask = Task { [weak self] in
                let result = await Task.detached(priority: .userInitiated) { try OfflineCaptureLoader.load(url) }.result
                guard let self, !Task.isCancelled, offlineGeneration == generation else { return }
                switch result {
                case let .success(loaded): installOfflineCapture(loaded)
                case let .failure(error): failOfflineCapture(error)
                }
            }
        }

        /// Already-frozen input boundary for tests and in-process importers; never uses MIDI.
        func importOfflineCapture(data: Data, name: String) {
            pauseOfflineReplay()
            offlineImportTask?.cancel(); offlineGeneration = UUID()
            do { try installOfflineCapture(OfflineCaptureLoader.parse(data, name: name)) }
            catch { failOfflineCapture(error) }
        }

        func clearOfflineCapture() {
            pauseOfflineReplay()
            offlineImportTask?.cancel(); offlineImportTask = nil; offlineGeneration = UUID()
            offlineCaptureState = .init()
        }

        func stepOfflineReplay() {
            guard !offlineCaptureState.isPlaying, !offlineCaptureState.isLoading else { return }
            _ = advanceOfflineReplay(steps: 1)
        }

        func runOfflineReplay() {
            guard !offlineCaptureState.isLoading, offlineCaptureState.replay?.isAtEnd == false else { return }
            pauseOfflineReplay()
            let generation = offlineReplayGeneration
            offlineCaptureState.isPlaying = true
            offlineReplayTask = Task { [weak self] in
                while !Task.isCancelled {
                    guard self?.advanceOfflineReplayBatch(generation) == true else { return }
                    await Task.yield()
                }
            }
        }

        func pauseOfflineReplay() {
            offlineReplayTask?.cancel(); offlineReplayTask = nil
            offlineReplayGeneration = UUID(); offlineCaptureState.isPlaying = false
        }

        func resetOfflineReplay() {
            guard !offlineCaptureState.isLoading else { return }
            pauseOfflineReplay()
            do { try offlineCaptureState.replay?.reset() }
            catch { offlineCaptureState.failure = LocalizedMessage("Replay stopped: invalid recorded state.") }
        }

        func setOfflineReplayFader(_ index: Int, value: UInt8) {
            guard !offlineCaptureState.isLoading, !offlineCaptureState.isPlaying else { return }
            do { try offlineCaptureState.replay?.setFader(index, value: value) }
            catch { offlineCaptureState.failure = LocalizedMessage("Replay stopped: invalid recorded state.") }
        }

        private func advanceOfflineReplayBatch(_ generation: UUID) -> Bool {
            guard offlineReplayGeneration == generation, offlineCaptureState.isPlaying else { return false }
            let continuing = advanceOfflineReplay(steps: 128)
            if !continuing {
                offlineCaptureState.isPlaying = false; offlineReplayTask = nil
            }
            return continuing
        }

        private func advanceOfflineReplay(steps: Int) -> Bool {
            guard var replay = offlineCaptureState.replay else { return false }
            do {
                for _ in 0 ..< steps {
                    if try !replay.step() {
                        break
                    }
                }
                offlineCaptureState.replay = replay
                return !replay.isAtEnd
            } catch {
                offlineCaptureState.failure = LocalizedMessage("Replay stopped: invalid recorded state.")
                return false
            }
        }

        private func installOfflineCapture(_ loaded: LoadedOfflineCapture) {
            do { offlineCaptureState = try OfflineCaptureWorkspace(loaded: loaded, replay: RecordedCaptureReplay(capture: loaded.capture)) }
            catch { failOfflineCapture(error) }
        }

        private func failOfflineCapture(_ error: any Error) {
            offlineCaptureState.isLoading = false
            switch error {
            case CaptureDocumentError.tooLarge:
                offlineCaptureState.failure = LocalizedMessage("Capture exceeds the 16 MiB import limit.")
            case CaptureDocumentError.tooManyEvents:
                offlineCaptureState.failure = LocalizedMessage("Capture exceeds the 100000 event import limit.")
            case let CaptureDocumentError.invalidRecord(line):
                offlineCaptureState.failure = LocalizedMessage("Invalid capture metadata or MIDI bytes at line %@. Original preserved.", String(line))
            default:
                offlineCaptureState.failure = LocalizedMessage("Cannot read this regular capture file. Original preserved.")
            }
        }
    }
#endif
