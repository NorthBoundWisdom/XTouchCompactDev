#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
#endif
#if os(macOS)
    @Test @MainActor func actualMCPListenerUsesLoopbackAndMemoryToken() async throws {
        let server = LocalMCPServer()
        defer { server.stop() }
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
        request.setValue("https://evil.invalid", forHTTPHeaderField: "Origin")
        let (_, denied) = try await URLSession.shared.data(for: request)
        #expect((denied as? HTTPURLResponse)?.statusCode == 403)
    }
#endif
