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

    @MainActor private func request(_ object: Any) throws -> HTTPRequest {
        try HTTPRequest(method: "POST", path: "/mcp", headers: ["authorization": "Bearer t", "content-type": "application/json"], body: JSONSerialization.data(withJSONObject: object))
    }

    @Test @MainActor func batchPreflightAndBudgetRejectBeforeAnyWriteAndReportPerItemErrors() throws {
        let server = LocalMCPServer(authenticationToken: "t")
        var writes = 0
        server.handler = { object in
            if object["method"] as? String == "unknown" {
                throw MCPError.methodNotFound
            }
            writes += 1; return ["written": true]
        }
        let call: [String: Any] = ["jsonrpc": "2.0", "id": 1, "method": "tools/call"]
        #expect(try server.respond(request([call, ["id": 2, "method": "bad"]])).0 == 400)
        #expect(writes == 0)
        let invalidID: [String: Any] = ["jsonrpc": "2.0", "id": ["invalid": true], "method": "tools/call"]
        #expect(try server.respond(request([call, invalidID])).0 == 400)
        #expect(writes == 0)
        let ping: [String: Any] = ["jsonrpc": "2.0", "id": 0, "method": "ping"]
        for _ in 0 ..< 59 {
            #expect(try server.respond(request(ping)).0 == 200)
        }
        #expect(try server.respond(request([call, call])).0 == 429)
        #expect(writes == 0)
        let fresh = LocalMCPServer(authenticationToken: "t")
        fresh.handler = server.handler
        let unknown: [String: Any] = ["jsonrpc": "2.0", "id": 2, "method": "unknown"]
        let notification: [String: Any] = ["jsonrpc": "2.0", "method": "notifications/initialized"]
        let (status, data) = try fresh.respond(request([call, unknown, notification]))
        #expect(status == 200)
        #expect(writes == 1)
        let responses = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        #expect(responses.count == 2)
        #expect(responses[0]["result"] != nil)
        #expect((responses[1]["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

    @Test @MainActor func agentCannotApproveItselfAndStateExposesDeferredMotors() throws {
        var time: TimeInterval = 10
        let model = ConsoleModel(startsMIDI: false, now: { Date(timeIntervalSince1970: time) })
        model.mcpWritesAllowed = true
        func call(_ name: String, _ args: [String: Any] = [:]) -> [String: Any] {
            ["method": "tools/call", "params": ["name": name, "arguments": args]]
        }
        _ = try model.routeMCP(call("agent_primary", ["slot": 1]))
        #expect(model.agents.slots[0].phase == .queued)
        _ = try model.routeMCP(call("agent_primary", ["slot": 1]))
        #expect(model.agents.slots[0].phase == .interrupted)
        _ = try model.routeMCP(call("agent_primary", ["slot": 1]))
        time = 12.7; model.advanceAgents()
        #expect(model.agents.slots[0].phase == .waitingApproval)
        #expect(throws: MCPError.self) { _ = try model.routeMCP(call("agent_primary", ["slot": 1])) }
        #expect(model.agents.slots[0].phase == .waitingApproval)
        model.agentPrimary(1) // Explicit user-interface approval remains supported.
        #expect(model.agents.slots[0].statusKey == "agent.mock.approved")
        model.touchFader(1, isTouched: true)
        _ = try model.routeMCP(call("set_parameter", ["id": "a.Fader.1", "value": 90]))
        let response = try model.routeMCP(call("get_state"))
        let content = try #require(response["content"] as? [[String: Any]])
        let text = try #require(content[0]["text"] as? String)
        let state = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        #expect(state["touchedFaders"] as? [Int] == [1])
        #expect(state["pendingMotors"] as? [Int] == [1])
        #expect(state["layer"] as? String == "a")
        let server = LocalMCPServer(authenticationToken: "t")
        server.handler = { try model.routeMCP($0) }
        let (_, data) = try server.respond(request(["jsonrpc": "2.0", "id": 1, "method": "missing"]))
        let rpc = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((rpc["error"] as? [String: Any])?["code"] as? Int == -32601)
    }

#endif
