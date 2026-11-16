import Foundation
import SurfacePluginContracts

public enum MCPVersions {
    public static let current = "2026-07-28"
    public static let legacy = "2025-11-25"
    public static let supported = [current, legacy]
}

public enum MCPRequestID: Equatable, Sendable {
    case string(String), integer(Int), number(Double)

    init?(_ value: JSONValue) {
        switch value {
        case let .string(value): self = .string(value)
        case let .number(value): self = .integer(value)
        case let .double(value) where value.isFinite: self = .number(value)
        default: return nil
        }
    }

    public var jsonValue: JSONValue {
        switch self {
        case let .string(value): .string(value)
        case let .integer(value): .number(value)
        case let .number(value): .double(value)
        }
    }
}

public struct MCPRequest: Sendable {
    public let id: MCPRequestID?
    public let method: String
    public let params: [String: JSONValue]
    public var jsonValue: JSONValue {
        var object: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)]
        if let id {
            object["id"] = id.jsonValue
        }
        return .object(object)
    }
}

public struct MCPRPCError: Error, Codable, Equatable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?
    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code; self.message = message; self.data = data
    }
}

public struct MCPResponse: Encodable, Sendable {
    public let jsonrpc = "2.0"
    public let id: JSONValue
    public let result: JSONValue?
    public let error: MCPRPCError?
}

public struct MCPReply: Sendable {
    public let status: Int
    public let response: MCPResponse?
    public let sessionID: String?
    public init(status: Int = 200, response: MCPResponse? = nil, sessionID: String? = nil) {
        self.status = status; self.response = response; self.sessionID = sessionID
    }

    public func encodedBody() throws -> Data {
        try response.map { try JSONEncoder().encode($0) } ?? Data()
    }
}

/// Pure protocol state: the host supplies time, build identity and tool execution.
/// HTTP authentication, loopback binding and request rate limits remain in the host.
@MainActor public final class MCPRouter {
    public var handler: ((MCPRequest) throws -> JSONValue)?
    public var sessionCount: Int {
        sessions.count
    }

    private struct Session { var initialized: Bool; var seen: Date }
    private var sessions: [String: Session] = [:]
    private let now: () -> Date
    private let serverInfo: JSONValue

    public init(serverVersion: String, now: @escaping () -> Date) {
        serverInfo = .object(["name": .string("XTouchCompactDev"), "version": .string(serverVersion)])
        self.now = now
    }

    public func stop() {
        sessions.removeAll()
    }

    public func deleteSession(_ id: String?) -> MCPReply {
        guard let id, sessions.removeValue(forKey: id) != nil else { return MCPReply(status: 404) }
        return MCPReply()
    }

    public func handle(_ data: Data, headers: [String: String]) -> MCPReply {
        let value: JSONValue
        do { value = try JSONDecoder().decode(JSONValue.self, from: data) }
        catch { return failure(-32700, "Parse error", status: 400) }
        guard let object = value.objectValue, object["jsonrpc"] == .string("2.0"),
              let method = object["method"]?.stringValue, !method.isEmpty
        else {
            return failure(-32600, "Invalid Request", status: 400)
        }
        let requestID = object["id"].flatMap(MCPRequestID.init)
        if object["id"] != nil, requestID == nil {
            return failure(-32600, "Invalid request id", status: 400)
        }
        let id = requestID?.jsonValue ?? .null
        guard object["params"] == nil || object["params"]?.objectValue != nil else {
            return failure(-32602, "params must be an object", id: id)
        }
        let params = object["params"]?.objectValue ?? [:]
        let request = MCPRequest(id: requestID, method: method, params: params)
        let meta = params["_meta"]?.objectValue
        let declared = meta?["io.modelcontextprotocol/protocolVersion"]?.stringValue
        let headerVersion = headers["mcp-protocol-version"]
        let modern = declared != nil || headerVersion == MCPVersions.current
        if modern {
            guard let declared, declared == headerVersion, headers["mcp-method"] == method,
                  meta?["io.modelcontextprotocol/clientCapabilities"]?.objectValue != nil
            else {
                return failure(-32020, "Required MCP metadata or mirrored headers do not match", id: id, status: 400)
            }
            guard declared == MCPVersions.current else {
                return failure(-32022, "Unsupported protocol version", id: id, status: 400,
                               data: .object(["supported": .array(MCPVersions.supported.map(JSONValue.string)), "requested": .string(declared)]))
            }
            if method == "tools/call" {
                guard let name = params["name"]?.stringValue, decodeHeader(headers["mcp-name"]) == name else {
                    return failure(-32020, "Mcp-Name does not match params.name", id: id, status: 400)
                }
            }
        } else if method == "initialize" {
            guard requestID != nil, params["protocolVersion"]?.stringValue != nil,
                  let info = params["clientInfo"]?.objectValue,
                  info["name"]?.stringValue != nil, info["version"]?.stringValue != nil,
                  params["capabilities"]?.objectValue != nil
            else {
                return failure(-32602, "Invalid initialize parameters", id: id)
            }
            expireSessions()
            guard sessions.count < 32 else { return failure(-32000, "Session capacity exceeded", id: id, status: 429) }
            let sessionID = UUID().uuidString
            sessions[sessionID] = Session(initialized: false, seen: now())
            return success(id, .object([
                "protocolVersion": .string(MCPVersions.legacy), "serverInfo": serverInfo,
                "capabilities": capabilities,
            ]), sessionID: sessionID)
        } else {
            expireSessions()
            guard let sessionID = headers["mcp-session-id"], var session = sessions[sessionID] else {
                return failure(-32000, "Unknown or missing MCP session", id: id, status: headers["mcp-session-id"] == nil ? 400 : 404)
            }
            guard headerVersion == MCPVersions.legacy else {
                return failure(-32602, "MCP-Protocol-Version must match the initialized session", id: id, status: 400)
            }
            if method == "notifications/initialized", requestID == nil {
                session.initialized = true; session.seen = now(); sessions[sessionID] = session
                return MCPReply(status: 202)
            }
            guard session.initialized else { return failure(-32002, "Session is not initialized", id: id) }
            session.seen = now(); sessions[sessionID] = session
        }
        // Notifications never execute tools and never return a JSON-RPC message.
        guard requestID != nil else { return MCPReply(status: 202) }
        do {
            let result: JSONValue
            switch method {
            case "server/discover" where modern:
                result = .object([
                    "supportedVersions": .array(MCPVersions.supported.map(JSONValue.string)),
                    "capabilities": capabilities,
                    "instructions": .string("Local XTouch parameters; writes obey permissions, agentWritable, touch gates and motor authorization."),
                ])
            case "ping": result = .object([:])
            case "tools/list", "tools/call":
                if method == "tools/call" {
                    guard let name = params["name"]?.stringValue, name.utf8.count <= 128 else {
                        return failure(-32602, "Tool name is required", id: id)
                    }
                }
                guard let handler else { return failure(-32601, "Method not found", id: id) }
                result = try handler(request)
            default: return failure(-32601, "Method not found", id: id, status: modern ? 404 : 200)
            }
            return success(id, result, modern: modern)
        } catch let error as MCPRPCError {
            return failure(error.code, error.message, id: id, data: error.data)
        } catch { return failure(-32603, "Could not encode tool result", id: id) }
    }

    private var capabilities: JSONValue {
        .object(["tools": .object(["listChanged": .bool(false)]), "experimental": .object([:])])
    }

    private func success(_ id: JSONValue, _ value: JSONValue, modern: Bool = false, sessionID: String? = nil) -> MCPReply {
        guard var result = value.objectValue else { return failure(-32603, "Result must be an object", id: id) }
        if modern {
            result["resultType"] = .string("complete")
            result["_meta"] = .object(["io.modelcontextprotocol/serverInfo": serverInfo])
        }
        return MCPReply(response: MCPResponse(id: id, result: .object(result), error: nil), sessionID: sessionID)
    }

    private func failure(_ code: Int, _ message: String, id: JSONValue = .null, status: Int = 200, data: JSONValue? = nil) -> MCPReply {
        MCPReply(status: status, response: MCPResponse(id: id, result: nil, error: MCPRPCError(code: code, message: message, data: data)))
    }

    private func decodeHeader(_ value: String?) -> String? {
        guard let value else { return nil }
        if value.hasPrefix("=?base64?"), value.hasSuffix("?=") {
            return Data(base64Encoded: String(value.dropFirst(9).dropLast(2))).flatMap { String(data: $0, encoding: .utf8) }
        }
        return value.unicodeScalars.allSatisfy { (0x21 ... 0x7E).contains($0.value) } ? value : nil
    }

    private func expireSessions() {
        let time = now()
        for id in sessions.filter({ time.timeIntervalSince($0.value.seen) >= 1800 }).map(\.key) {
            sessions[id] = nil
        }
    }
}
