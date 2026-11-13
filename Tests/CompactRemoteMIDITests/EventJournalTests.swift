import CompactRemoteMIDI
import Foundation
import Testing
#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

private final class MemoryEventWriter: RemoteEventWriting {
    var bytes = Data()
    var appends = 0
    var flushes = 0
    var closes = 0
    var appendFailure: POSIXErrorCode?
    var flushFailure = false
    var partialWrite = false
    func append(_ data: Data) throws {
        appends += 1
        if partialWrite {
            bytes.append(data.prefix(7)); throw POSIXError(.EINTR)
        }
        if let appendFailure {
            throw POSIXError(appendFailure)
        }
        bytes.append(data)
    }

    func synchronize() throws {
        flushes += 1
        if flushFailure {
            throw POSIXError(.ENOSPC)
        }
    }

    func close() throws {
        closes += 1
    }
}

@Test func eventJournalAppendsPreservesOriginalAndDoesNotOwnStdout() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("events.jsonl")
    let original = Data("{\"old\":true}\n".utf8)
    try original.write(to: path)
    let output = MemoryEventWriter()
    // A real file writer is exercised via the public path initializer; stdout is suppressed.
    let journal = try RemoteEventJournal(path: path.path)
    let date = Date(timeIntervalSince1970: 123)
    for event in ["one", "two"] {
        try journal.emit(["event": event], at: date, stdout: false)
    }
    try journal.close()
    var expected = original
    for event in ["one", "two"] {
        try expected.append(RemoteEventJSON.line(["event": event], at: date))
    }
    #expect(try Data(contentsOf: path) == expected)
    let borrowed = RemoteEventJournal(file: nil, output: output)
    try borrowed.emit(["event": "stdout"], at: date)
    try borrowed.close()
    #expect(output.appends == 1 && output.closes == 0)
    #expect(throws: RemoteJournalError.closed) { try borrowed.emit(["event": "late"]) }
}

@Test func journalOpenRefusalHappensBeforeAnyOutput() {
    let output = MemoryEventWriter()
    #expect(throws: POSIXError.self) {
        try RemoteEventJournal(path: "denied", opener: { _ in throw POSIXError(.EACCES) }, output: output)
    }
    #expect(output.bytes.isEmpty && output.closes == 0)
}

@Test func journalWriteFlushAndPartialFailuresAreTerminalWithoutRetry() throws {
    for failure in 0 ... 3 {
        let file = MemoryEventWriter(), output = MemoryEventWriter()
        if failure == 0 {
            file.appendFailure = .EACCES
        }
        if failure == 1 {
            file.appendFailure = .ENOSPC
        }
        if failure == 2 {
            file.flushFailure = true
        }
        if failure == 3 {
            file.partialWrite = true
        }
        let journal = RemoteEventJournal(file: file, output: output)
        #expect(throws: POSIXError.self) { try journal.emit(["event": "not-acknowledged"]) }
        let preserved = file.bytes
        #expect(throws: RemoteJournalError.closed) { try journal.emit(["event": "retry"]) }
        try journal.close()
        #expect(file.appends == 1 && file.closes == 1)
        #expect(file.bytes == preserved)
        #expect(output.bytes.isEmpty) // Failed durable log never publishes stdout success.
        #expect(output.closes == 0)
    }
}

@Test func journalOutputFailureAndCloseFlushFailureReleaseOwnedFile() throws {
    let file = MemoryEventWriter(), output = MemoryEventWriter()
    output.appendFailure = .EPIPE
    let journal = RemoteEventJournal(file: file, output: output)
    #expect(throws: POSIXError.self) { try journal.emit(["event": "durable-before-output-failure"]) }
    #expect(!file.bytes.isEmpty && file.closes == 1)
    #expect(throws: RemoteJournalError.closed) { try journal.emit(["event": "retry"]) }
    let other = MemoryEventWriter()
    let closing = RemoteEventJournal(file: other, output: MemoryEventWriter())
    other.flushFailure = true
    #expect(throws: POSIXError.self) { try closing.close() }
    try closing.close()
    #expect(other.closes == 1)
}

@Test func journalRejectsSymlinkAndFIFOAndCreatesPrivateRegularFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let path = root.appendingPathComponent("new.jsonl")
    let journal = try RemoteEventJournal(path: path.path)
    try journal.emit(["event": "created"], stdout: false); try journal.close()
    let permissions = try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber
    #expect(permissions.map { $0.intValue & 0o077 } == 0)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
    let original = try Data(contentsOf: path)
    #expect(throws: (any Error).self) { try RemoteEventJournal(path: link.path) }
    #expect(try Data(contentsOf: path) == original)
    let fifo = root.appendingPathComponent("fifo")
    #expect(mkfifo(fifo.path, 0o600) == 0)
    #expect(throws: (any Error).self) { try RemoteEventJournal(path: fifo.path) }
}

@Test func journalSerializesConcurrentCompleteRecords() throws {
    let file = MemoryEventWriter(), output = MemoryEventWriter()
    let journal = RemoteEventJournal(file: file, output: output)
    DispatchQueue.concurrentPerform(iterations: 32) { index in
        try! journal.emit(["event": "concurrent", "index": index], at: Date(timeIntervalSince1970: 0))
    }
    try journal.close()
    let rows = try file.bytes.split(separator: 10).map { try JSONSerialization.jsonObject(with: Data($0)) as! [String: Any] }
    #expect(rows.count == 32)
    #expect(Set(rows.compactMap { $0["index"] as? Int }) == Set(0 ..< 32))
    #expect(file.bytes == output.bytes)
    #expect(file.closes == 1 && output.closes == 0)
}

@Test func journalEncodingFailureIsTerminalAndOptionalLoggingOpensNothing() throws {
    let file = MemoryEventWriter(), output = MemoryEventWriter()
    let journal = RemoteEventJournal(file: file, output: output)
    #expect(throws: (any Error).self) { try journal.emit(["bad": Double.nan]) }
    #expect(file.bytes.isEmpty && output.bytes.isEmpty && file.closes == 1)
    #expect(throws: RemoteJournalError.closed) { try journal.emit(["event": "retry"]) }
    let optional = try RemoteEventJournal(path: nil, opener: { _ in throw POSIXError(.EACCES) }, output: output)
    try optional.emit(["bad": Double.nan], stdout: false) // No destination means no work.
    try optional.emit(["event": "stdout-only"])
    try optional.close()
    #expect(output.appends == 1 && output.closes == 0)
}
