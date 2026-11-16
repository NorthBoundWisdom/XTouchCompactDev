import Foundation
import SurfacePluginContracts
import Testing
@testable import XTouchCompactCore

@MainActor private func protocolRouter() -> MCPRouter {
    MCPRouter(serverVersion: "9.8.7+42", now: { Date(timeIntervalSince1970: 100) })
}

private func modern(_ method: String, params: [String: JSONValue] = [:], version: String = MCPVersions.current, notification: Bool = false) throws -> (Data, [String: String]) {
    var params = params
    params["_meta"] = .object([
        "io.modelcontextprotocol/protocolVersion": .string(version),
        "io.modelcontextprotocol/clientCapabilities": .object([:]),
    ])
    var object: [String: JSONValue] = ["jsonrpc": .string("2.0"), "method": .string(method), "params": .object(params)]
    if !notification {
        object["id"] = .number(1)
    }
    var headers = ["mcp-protocol-version": version, "mcp-method": method]
    headers["mcp-name"] = params["name"]?.stringValue
    return try (JSONEncoder().encode(JSONValue.object(object)), headers)
}

@MainActor private func send(_ router: MCPRouter, _ message: (Data, [String: String])) -> MCPReply {
    router.handle(message.0, headers: message.1)
}

private func initialize(_ version: String = MCPVersions.legacy) throws -> Data {
    try JSONEncoder().encode(JSONValue.object([
        "jsonrpc": .string("2.0"), "id": .string("init"), "method": .string("initialize"),
        "params": .object(["protocolVersion": .string(version), "capabilities": .object([:]),
                           "clientInfo": .object(["name": .string("generic"), "version": .string("1")])]),
    ]))
}

@Test @MainActor func modernMCPDiscoveryAndToolShapesCarryActualBuildIdentity() throws {
    let router = protocolRouter()
    router.handler = { request in
        if request.method == "tools/list" {
            return .object(["tools": .array([])])
        }
        return .object(["content": .array([.object(["type": .string("text"), "text": .string("{\"data\":1}")])]),
                        "structuredContent": .object(["data": .number(1)]), "isError": .bool(false)])
    }
    let discovery = try send(router, modern("server/discover"))
    #expect(discovery.status == 200)
    #expect(discovery.sessionID == nil && router.sessionCount == 0)
    #expect(discovery.response?.result?.value(for: "supportedVersions") == .array(MCPVersions.supported.map(JSONValue.string)))
    #expect(discovery.response?.result?.value(for: "resultType") == .string("complete"))
    let info = discovery.response?.result?.value(for: "_meta")?.value(for: "io.modelcontextprotocol/serverInfo")
    #expect(info?.value(for: "version") == .string("9.8.7+42"))
    #expect(try send(router, modern("tools/list")).response?.result?.value(for: "tools") == .array([]))
    let result = try send(router, modern("tools/call", params: ["name": .string("read")])).response?.result
    #expect(result?.value(for: "structuredContent") == .object(["data": .number(1)]))
    #expect(result?.value(for: "isError") == .bool(false))
    #expect(try send(router, modern("unknown")).status == 404)
    #expect(try send(router, modern("unknown")).response?.error?.code == -32601)
}

@Test @MainActor func legacyMCPHandshakeFallbackExpiryDeletionAndCapacity() throws {
    var time = Date(timeIntervalSince1970: 100)
    let router = MCPRouter(serverVersion: "build", now: { time })
    for requested in [MCPVersions.legacy, "2025-03-26", "2099-01-01"] {
        let initialized = try router.handle(initialize(requested), headers: [:])
        #expect(initialized.response?.result?.value(for: "protocolVersion") == .string(MCPVersions.legacy))
        let session = try #require(initialized.sessionID)
        let headers = ["mcp-protocol-version": MCPVersions.legacy, "mcp-session-id": session]
        let ping = Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8)
        #expect(router.handle(ping, headers: headers).response?.error?.code == -32002)
        let ready = router.handle(Data(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#.utf8), headers: headers)
        #expect(ready.status == 202 && ready.response == nil)
        #expect(router.handle(ping, headers: headers).response?.result == .object([:]))
        #expect(router.handle(ping, headers: ["mcp-session-id": session, "mcp-protocol-version": "2025-03-26"]).status == 400)
        #expect(router.deleteSession(session).status == 200)
        #expect(router.handle(ping, headers: headers).status == 404)
    }
    let expiring = try #require(router.handle(initialize(), headers: [:]).sessionID)
    time.addTimeInterval(1800)
    let ping = Data(#"{"jsonrpc":"2.0","id":2,"method":"ping"}"#.utf8)
    #expect(router.handle(ping, headers: ["mcp-session-id": expiring, "mcp-protocol-version": MCPVersions.legacy]).status == 404)
    for _ in 0 ..< 32 {
        #expect(try router.handle(initialize(), headers: [:]).status == 200)
    }
    #expect(try router.handle(initialize(), headers: [:]).status == 429)
    router.stop()
    #expect(router.sessionCount == 0)
}

@Test @MainActor func malformedMCPAndMirroredMetadataFailBeforeToolExecution() throws {
    let router = protocolRouter()
    var calls = 0
    router.handler = { _ in calls += 1; return .object([:]) }
    for (raw, code) in [("{", -32700), ("[]", -32600), ("{}", -32600),
                        (#"{"jsonrpc":"2.0","id":true,"method":"ping"}"#, -32600),
                        (#"{"jsonrpc":"2.0","id":null,"method":"ping"}"#, -32600),
                        (#"{"jsonrpc":"2.0","id":1,"method":"ping","params":[]}"#, -32602)]
    {
        #expect(router.handle(Data(raw.utf8), headers: [:]).response?.error?.code == code)
    }
    let unknown = try send(router, modern("ping", version: "2099-01-01"))
    #expect(unknown.status == 400 && unknown.response?.error?.code == -32022)
    #expect(unknown.response?.error?.data?.value(for: "supported") == .array(MCPVersions.supported.map(JSONValue.string)))
    let (data, headers) = try modern("tools/call", params: ["name": .string("write")])
    for key in ["mcp-method", "mcp-name", "mcp-protocol-version"] {
        var broken = headers; broken[key] = "mismatch"
        #expect(router.handle(data, headers: broken).response?.error?.code == -32020)
    }
    #expect(calls == 0)
    let notification = try send(router, modern("tools/call", params: ["name": .string("write")], notification: true))
    #expect(notification.status == 202 && notification.response == nil)
    #expect(calls == 0)
    let encoded = try #require(try send(router, modern("ping")).encodedBody() as Data?)
    #expect(try JSONDecoder().decode(JSONValue.self, from: encoded).value(for: "error") == nil)
}
