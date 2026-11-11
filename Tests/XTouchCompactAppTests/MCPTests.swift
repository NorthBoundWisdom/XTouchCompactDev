#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp

    @Test @MainActor func mcpAuthenticationOriginRateAndPermissions() throws {
        let server = LocalMCPServer(authenticationToken: "test-token")
        let model = ConsoleModel(startsMIDI: false)
        server.handler = { try model.routeMCP($0) }
        let body = try JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "method": "tools/list"])
        var request = HTTPRequest(method: "POST", path: "/mcp", headers: ["content-type": "application/json"], body: body)
        #expect(server.respond(request).0 == 401)
        request.headers["authorization"] = "Bearer test-token"
        request.headers["origin"] = "https://example.com"
        #expect(server.respond(request).0 == 403)
        request.headers.removeValue(forKey: "origin")
        #expect(server.respond(request).0 == 200)
        for _ in 0 ..< 59 {
            _ = server.respond(request)
        }
        #expect(server.respond(request).0 == 429)
        let call: [String: Any] = ["method": "tools/call", "params": ["name": "set_parameter", "arguments": ["id": "a.Fader.1", "value": 90]]]
        #expect(throws: MCPError.self) { _ = try model.routeMCP(call) }
        model.mcpWritesAllowed = true
        model.touchFader(1, isTouched: true)
        _ = try model.routeMCP(call)
        #expect(model.session.state.isMotorPending(1))
        #expect(model.bank.faders[0] == 90)
        #expect(!model.events.contains { $0.direction == .output && $0.control == .fader(1) })
        let bytes = Data("POST /mcp HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}".utf8)
        #expect(throws: MCPError.self) { _ = try HTTPRequest.parse(bytes) }
    }
#endif
