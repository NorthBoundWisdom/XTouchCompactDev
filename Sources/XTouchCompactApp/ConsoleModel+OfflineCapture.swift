#if os(macOS)
    import AppKit
    import Foundation
    import UniformTypeIdentifiers
    import XTouchCompactCore
    import XTouchCompactLocalization

    extension ConsoleModel {
        func chooseOfflineCapture() {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [UTType(filenameExtension: "jsonl") ?? .data, .json]
            panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
            if panel.runModal() == .OK, let url = panel.url {
                loadOfflineCapture(url)
            }
        }

        func loadOfflineCapture(_ url: URL) {
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
            offlineImportTask?.cancel(); offlineGeneration = UUID()
            do { try installOfflineCapture(OfflineCaptureLoader.parse(data, name: name)) }
            catch { failOfflineCapture(error) }
        }

        func clearOfflineCapture() {
            offlineImportTask?.cancel(); offlineImportTask = nil; offlineGeneration = UUID()
            offlineCaptureState = .init()
        }

        private func installOfflineCapture(_ loaded: LoadedOfflineCapture) {
            offlineCaptureState = OfflineCaptureWorkspace(loaded: loaded)
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
