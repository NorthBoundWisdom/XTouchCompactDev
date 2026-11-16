#if os(macOS)
    import Foundation

    /// Process integration entry: no AppKit, defaults, disk workspace, Keychain or CoreMIDI.
    @MainActor enum MCPIntegrationCommand {
        static func run() -> Never {
            #if DEBUG
                let arguments = ProcessInfo.processInfo.arguments
                let token = ProcessInfo.processInfo.environment["XTOUCH_MCP_TOKEN"] ?? ""
                guard arguments.contains("--integration-test"), !token.isEmpty,
                      !token.contains("\n"), !token.contains("\r"),
                      !arguments.contains("--hardware-observe"), !arguments.contains("--hardware-control")
                else {
                    fail()
                }
                let model = ConsoleModel(startsMIDI: false, isolated: true)
                model.mcpWritesAllowed = arguments.contains("--allow-writes")
                model.mcp.handler = { [weak model] request in
                    guard let model else { throw MCPError.denied }
                    return try model.routeMCP(request)
                }
                model.mcp.readSource = { [weak model] in model?.hardwareMode == false ? "mock" : "hardware" }
                model.mcp.onReady = { port in
                    print("{\"type\":\"xtouch.mcp_test_ready\",\"url\":\"http://127.0.0.1:\(port)/mcp\",\"hardwareAccessed\":false}")
                    fflush(stdout)
                }
                do { try model.mcp.start(port: 0, token: token) }
                catch { fail() }
                withExtendedLifetime(model) { dispatchMain() }
            #else
                fail()
            #endif
        }

        private static func fail() -> Never {
            FileHandle.standardError.write(Data("MCP test server requires a Debug integration launch, a token environment variable and Mock source.\n".utf8))
            exit(2)
        }
    }
#endif
