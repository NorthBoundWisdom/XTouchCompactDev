import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Private host-issued principals, independent of credential contents. The single authenticated
/// bearer credential is bound to `remote` by the startup composition, never by a request.
struct SurfacePrincipals: Codable, Sendable {
    let schema_version: Int
    let remote_writer_id: String
    let interface_writer_id: String
    let system_writer_id: String

    enum Invalid: Error { case privateFile, record, creation }

    static func fresh() -> Self {
        func randomID() -> String {
            (0 ..< 16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        }
        var ids: [String] = []
        while ids.count < 3 {
            let id = randomID()
            if !ids.contains(id) {
                ids.append(id)
            }
        }
        return .init(schema_version: 1, remote_writer_id: ids[0], interface_writer_id: ids[1], system_writer_id: ids[2])
    }

    private func validate() throws {
        let ids = [remote_writer_id, interface_writer_id, system_writer_id]
        guard schema_version == 1, Set(ids).count == 3,
              ids.allSatisfy({ $0.utf8.count == 32 && $0.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) } })
        else { throw Invalid.record }
    }

    /// No path means memory-only. Call only for a running authenticated host, never --describe.
    static func loadOrCreate(path: String?) throws -> Self {
        guard let path else { return fresh() }
        let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if descriptor >= 0 {
            defer { close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                  info.st_uid == getuid(), info.st_mode & 0o7777 == 0o600, info.st_size <= 4096
            else { throw Invalid.privateFile }
            var bytes = [UInt8](repeating: 0, count: 4097)
            let count = read(descriptor, &bytes, bytes.count)
            guard count >= 0, count <= 4096 else { throw Invalid.privateFile }
            let data = Data(bytes.prefix(count))
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  Set(object.keys) == ["schema_version", "remote_writer_id", "interface_writer_id", "system_writer_id"]
            else { throw Invalid.record }
            // Values are constrained below to integer/hex strings, so every JSON string token
            // followed by ':' is a root key. Duplicate (including escaped) keys are refused.
            let text = String(decoding: data, as: UTF8.self)
            let keyPattern = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"\s*:"#)
            guard keyPattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == 4 else { throw Invalid.record }
            let result = try JSONDecoder().decode(Self.self, from: data)
            try result.validate()
            return result
        }
        guard errno == ENOENT else { throw Invalid.privateFile }
        let result = fresh()
        try result.validate()
        let data = try JSONEncoder().encode(result) + Data("\n".utf8)
        // Stage in the destination's directory and link create-only. Readers see the complete
        // record, and a concurrent creator/symlink always wins without being overwritten.
        let url = URL(fileURLWithPath: path)
        var template = Array(url.deletingLastPathComponent().appendingPathComponent(".surface-principals-XXXXXX").path.utf8CString)
        let temporary = mkstemp(&template)
        guard temporary >= 0 else { throw Invalid.creation }
        defer { close(temporary); unlink(template) }
        guard fchmod(temporary, 0o600) == 0 else { throw Invalid.creation }
        let written = data.withUnsafeBytes { write(temporary, $0.baseAddress, $0.count) }
        guard written == data.count, fsync(temporary) == 0, link(template, path) == 0 else { throw Invalid.creation }
        return result
    }
}
