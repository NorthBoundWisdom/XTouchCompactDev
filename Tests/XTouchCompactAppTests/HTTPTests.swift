#if os(macOS)
    import Foundation
    import SurfacePluginContracts
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore
#endif
#if os(macOS)
    @Test @MainActor func actualMCPListenerUsesLoopbackAndMemoryToken() async throws {
        let server = LocalMCPServer()
        defer { server.stop() }
        let model = ConsoleModel(startsMIDI: false, isolated: true)
        server.handler = { try model.routeMCP($0) }
        try server.start(port: 0, token: "isolated-test-token")
        for _ in 0 ..< 100 where server.boundPort == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try #require(server.boundPort)
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer isolated-test-token", forHTTPHeaderField: "Authorization")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((object["result"] as? [String: Any])?["protocolVersion"] as? String == "2025-03-26")
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"surface_capabilities","arguments":{}}}"#.utf8)
        let (surfaceData, surfaceResponse) = try await URLSession.shared.data(for: request)
        #expect((surfaceResponse as? HTTPURLResponse)?.statusCode == 200)
        let rpc = try #require(JSONSerialization.jsonObject(with: surfaceData) as? [String: Any])
        let result = try #require(rpc["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        let shared = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        let structured = try #require(result["structuredContent"])
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: structured)) == shared)
        #expect(shared.value(for: "instances")?.arrayValue?.count == 1)
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"surface_agent_primary","arguments":{"instance_id":"agent","slot":1}}}"#.utf8)
        let (failureData, _) = try await URLSession.shared.data(for: request)
        let failureRPC = try #require(JSONSerialization.jsonObject(with: failureData) as? [String: Any])
        let failure = try #require(failureRPC["result"] as? [String: Any])
        #expect(failure["isError"] as? Bool == true)
        let failureContent = try #require(failure["content"] as? [[String: Any]])
        let failureText = try #require(failureContent.first?["text"] as? String)
        let failureValue = try JSONDecoder().decode(JSONValue.self, from: Data(failureText.utf8))
        let failureStructured = try #require(failure["structuredContent"])
        #expect(try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: failureStructured)) == failureValue)
        #expect(failureValue.value(for: "code") == .string("permissionDenied"))
        model.installOptionalPlugins([.robot])
        request.httpBody = Data(#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"surface_robot_trace","arguments":{"instance_id":"robot"}}}"#.utf8)
        let (traceData, _) = try await URLSession.shared.data(for: request)
        let traceRPC = try #require(JSONSerialization.jsonObject(with: traceData) as? [String: Any])
        let trace = try #require(traceRPC["result"] as? [String: Any])
        let traceStructured = try #require(trace["structuredContent"] as? [String: Any])
        #expect((traceStructured["samples"] as? [Any])?.isEmpty == true)
        let traceContent = try #require(trace["content"] as? [[String: Any]])
        let traceText = try #require(traceContent.first?["text"] as? String)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(traceText.utf8)) == .object(["samples": .array([])]))
        request.setValue("https://evil.invalid", forHTTPHeaderField: "Origin")
        let (_, denied) = try await URLSession.shared.data(for: request)
        #expect((denied as? HTTPURLResponse)?.statusCode == 403)
    }
#endif
