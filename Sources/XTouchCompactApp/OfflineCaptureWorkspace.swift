#if os(macOS)
    import CryptoKit
    import Darwin
    import Foundation
    import XTouchCompactCore
    import XTouchCompactLocalization

    struct LoadedOfflineCapture: Equatable, Sendable {
        let name: String
        let byteCount: Int
        let sha256: String
        let capture: RecordedCapture
        let audit: CaptureMotorAudit
    }

    struct OfflineCaptureWorkspace {
        var loaded: LoadedOfflineCapture?
        var isLoading = false
        var failure: LocalizedMessage?
        var replay: RecordedCaptureReplay?
        var isPlaying = false
    }

    enum OfflineCaptureReadError: Error { case notRegularFile }

    /// Reads a frozen bounded prefix. No writer, MIDI service or user settings are reachable.
    enum OfflineCaptureLoader {
        static func parse(_ data: Data, name: String) throws -> LoadedOfflineCapture {
            let capture = try RecordedCapture(data: data)
            return LoadedOfflineCapture(name: name, byteCount: data.count,
                                        sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                                        capture: capture, audit: CaptureMotorAudit(capture: capture))
        }

        static func load(_ url: URL) throws -> LoadedOfflineCapture {
            guard url.isFileURL, !url.path.contains("\0") else { throw OfflineCaptureReadError.notRegularFile }
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
                Darwin.close(fd); throw OfflineCaptureReadError.notRegularFile
            }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            defer { try? file.close() }
            guard info.st_size <= RecordedCapture.maximumBytes else { throw CaptureDocumentError.tooLarge }
            let data = try file.read(upToCount: RecordedCapture.maximumBytes + 1) ?? Data()
            return try parse(data, name: url.lastPathComponent)
        }
    }
#endif
