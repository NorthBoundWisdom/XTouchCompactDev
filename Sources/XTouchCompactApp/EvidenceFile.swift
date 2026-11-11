#if os(macOS)
    import Darwin
    import Foundation

    enum EvidenceError: Error { case fileExists, closed }

    protocol EvidenceWriting: AnyObject {
        func write(_ data: Data) throws
        func synchronize() throws
        func close() throws
    }

    /// Exclusive creation and a retained descriptor: a second capture/export cannot
    /// truncate evidence, and a final-component symlink is never followed.
    final class ExclusiveEvidenceFile: EvidenceWriting {
        private let handle: FileHandle
        private var closed = false

        init(url: URL) throws {
            guard url.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
            let descriptor = url.withUnsafeFileSystemRepresentation {
                Darwin.open($0!, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
            }
            guard descriptor >= 0 else {
                if errno == EEXIST {
                    throw EvidenceError.fileExists
                }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        }

        func write(_ data: Data) throws {
            guard !closed else { throw EvidenceError.closed }
            try handle.write(contentsOf: data)
        }

        func synchronize() throws {
            guard !closed else { throw EvidenceError.closed }
            try handle.synchronize()
        }

        func close() throws {
            guard !closed else { return }
            closed = true
            try handle.close()
        }
    }
#endif
