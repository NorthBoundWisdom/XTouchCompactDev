import Foundation
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

/// A journal owns only its file writer. The output writer is borrowed (e.g. stdout).
public protocol RemoteEventWriting: AnyObject {
    func append(_ data: Data) throws
    func synchronize() throws
    func close() throws
}

public enum RemoteJournalError: Error, Equatable, LocalizedError {
    case closed, invalidDestination
    public var errorDescription: String? {
        switch self {
        case .closed: "Event journal is closed or failed."
        case .invalidDestination: "Event log destination must be a regular file."
        }
    }
}

/// No CoreMIDI dependency. Complete records are serialized; any encoding/write/flush
/// failure permanently closes the journal. The caller decides how to stop its command.
public final class RemoteEventJournal: @unchecked Sendable {
    private let file: (any RemoteEventWriting)?
    private let output: any RemoteEventWriting
    private let lock = NSLock()
    private var closed = false

    public convenience init(path: String?) throws {
        try self.init(path: path, opener: { try AppendEventFile(path: $0) }, output: StandardEventOutput())
    }

    /// Injection permits permission/disk-full/interruption tests without any MIDI client.
    public convenience init(path: String?, opener: (String) throws -> any RemoteEventWriting,
                            output: any RemoteEventWriting) throws
    {
        try self.init(file: path.map(opener), output: output)
    }

    public init(file: (any RemoteEventWriting)?, output: any RemoteEventWriting) {
        self.file = file; self.output = output
    }

    deinit { try? close() }

    public func emit(_ fields: [String: Any], at date: Date = Date(), stdout: Bool = true) throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { throw RemoteJournalError.closed }
        guard stdout || file != nil else { return }
        do {
            let data = try RemoteEventJSON.line(fields, at: date)
            try file?.append(data)
            try file?.synchronize()
            if stdout {
                try output.append(data)
            }
        } catch {
            closed = true
            try? file?.close()
            throw error
        }
    }

    public func close() throws {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        do { try file?.synchronize() }
        catch { try? file?.close(); throw error }
        try file?.close()
    }
}

private final class StandardEventOutput: RemoteEventWriting {
    func append(_ data: Data) throws {
        try FileHandle.standardOutput.write(contentsOf: data)
    }

    func synchronize() throws {}
    func close() throws {} // Never close the process's stdout.
}

private final class AppendEventFile: RemoteEventWriting {
    private let handle: FileHandle
    init(path: String) throws {
        guard !path.isEmpty, !path.contains("\0") else { throw RemoteJournalError.invalidDestination }
        // O_NONBLOCK avoids hanging on a FIFO before fstat can reject it.
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, mode_t(0o600))
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            _ = systemClose(fd)
            throw RemoteJournalError.invalidDestination
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func append(_ data: Data) throws {
        try handle.write(contentsOf: data)
    }

    func synchronize() throws {
        try handle.synchronize()
    }

    func close() throws {
        try handle.close()
    }
}

private func systemClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
        Darwin.close(fd)
    #else
        Glibc.close(fd)
    #endif
}
