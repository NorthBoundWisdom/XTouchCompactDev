import Foundation
#if canImport(Darwin)
    import Darwin
#else
    import Glibc
#endif

/// Trusted transport context. Requests cannot select a scope or provide a writer ID.
public struct SurfaceClientContext: Sendable {
    public enum Scope: Sendable { case owner, `operator`, display }
    public let scope: Scope
    public let writerID: String?

    public func permits(_ tool: String) -> Bool {
        switch scope {
        case .owner: true
        case .operator: ["surface_control_discover", "surface_control_snapshot", "surface_control_events", "surface_control_input", "surface_control_renew"].contains(tool)
        case .display: ["surface_control_discover", "surface_control_snapshot", "surface_control_events", "surface_control_feedback"].contains(tool)
        }
    }

    static let owner = SurfaceClientContext(scope: .owner, writerID: nil)
}

/// Optional process-start credentials. Tokens are read from a dedicated pipe into memory only.
/// Existing single-token authentication and v1 principal files keep their original semantics.
public struct SurfaceClientCredentials: Sendable {
    public enum Invalid: Error { case dedicatedPipeRequired, record }
    public let ownerToken: String
    let clients: [String: SurfaceClientContext]
    private let additionalDisplays: Bool

    /// Only explicit extended records opt into independent display feedback budgets.
    public var independentDisplayWriterIDs: Set<String> {
        guard additionalDisplays else { return [] }
        return Set(clients.values.compactMap { client in
            if case .display = client.scope {
                return client.writerID
            }
            return nil
        })
    }

    /// Preserve the legacy host principals while guaranteeing all remote clients remain
    /// distinguishable, even if the random generator happens to collide with a stored ID.
    public func reservingWriterIDs(_ reserved: Set<String>) -> Self {
        var used = reserved
        var result = clients
        for (token, client) in clients {
            if case .owner = client.scope {
                continue
            }
            var id = client.writerID!
            while !used.insert(id).inserted {
                id = (0 ..< 16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
            }
            result[token] = .init(scope: client.scope, writerID: id)
        }
        return Self(ownerToken: ownerToken, clients: result, additionalDisplays: additionalDisplays)
    }

    public static func readStdin() throws -> Self {
        var info = stat()
        guard fstat(STDIN_FILENO, &info) == 0, info.st_mode & S_IFMT == S_IFIFO else { throw Invalid.dedicatedPipeRequired }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 2049)
        while true {
            let count = read(STDIN_FILENO, &bytes, 2049 - data.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count >= 0 else { throw Invalid.record }
            if count == 0 {
                break
            }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= 2048 else { throw Invalid.record }
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let owner = object["owner"] as? String, let operatorToken = object["operator"] as? String,
              let display = object["display"] as? String else { throw Invalid.record }
        let additional: [String]
        if object["displays"] != nil {
            guard Set(object.keys) == ["owner", "operator", "display", "displays"],
                  let values = object["displays"] as? [String], (1 ... 7).contains(values.count)
            else { throw Invalid.record }
            additional = values
        } else {
            guard Set(object.keys) == ["owner", "operator", "display"], data.count <= 512 else { throw Invalid.record }
            additional = []
        }
        let tokens = [owner, operatorToken, display] + additional
        guard Set(tokens).count == tokens.count,
              tokens.allSatisfy({ $0.utf8.count == 64 && $0.utf8.allSatisfy { (48 ... 57).contains($0) || (97 ... 102).contains($0) } })
        else { throw Invalid.record }
        // Only top-level keys exist: display array members are hex strings. Counting keys also
        // catches duplicate/escaped spellings that JSONSerialization would silently replace.
        let text = String(decoding: data, as: UTF8.self)
        let keys = try NSRegularExpression(pattern: #""(?:[^"\\]|\\.)*"\s*:"#)
        guard keys.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text)) == object.count else { throw Invalid.record }
        var writers = Set<String>()
        func writer() -> String {
            var result: String
            repeat {
                result = (0 ..< 16).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
            } while !writers.insert(result).inserted
            return result
        }
        var clients: [String: SurfaceClientContext] = [
            owner: .owner,
            operatorToken: .init(scope: .operator, writerID: writer()),
            display: .init(scope: .display, writerID: writer()),
        ]
        for token in additional {
            clients[token] = .init(scope: .display, writerID: writer())
        }
        return Self(ownerToken: owner, clients: clients, additionalDisplays: !additional.isEmpty)
    }
}
