#if os(macOS)
    import Foundation
    import RemoteToolContracts
    import SurfacePluginContracts
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @MainActor private func surfaceCall(_ model: ConsoleModel, _ name: String, _ args: [String: Any] = [:]) throws -> [String: Any] {
        try model.routeMCP(["method": "tools/call", "params": ["name": name, "arguments": args]])
    }

    private func surfaceValue(_ response: [String: Any]) throws -> JSONValue {
        let content = try #require(response["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        let result = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
        if let structured = response["structuredContent"] {
            #expect(try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: structured)) == result)
        }
        return result
    }

    @Test @MainActor func sharedRemoteSchemasAndCanonicalAgentKeepLegacyTools() throws {
        let clock = TestClock()
        let model = ConsoleModel(startsMIDI: false, now: { clock.date })
        let listing = try model.routeMCP(["method": "tools/list"])
        let tools = try #require(listing["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(Set(["get_state", "set_parameter", "agent_primary", "surface_capabilities", "surface_events", "surface_agent_snapshot", "surface_agent_primary", "surface_agent_interrupt"]).isSubset(of: names))
        for descriptor in model.plugins.remoteTools {
            let wire = try #require(tools.first { $0["name"] as? String == descriptor.name })
            for (key, schema) in [("inputSchema", descriptor.inputSchema), ("outputSchema", descriptor.outputSchema)] {
                #expect(try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: #require(wire[key]))) == schema)
            }
        }
        let denied = try surfaceCall(model, "surface_agent_primary", ["instance_id": "agent", "slot": 1])
        #expect(denied["isError"] as? Bool == true)
        #expect(try surfaceValue(denied).value(for: "code") == .string("permissionDenied"))
        model.mcpWritesAllowed = true
        _ = try surfaceCall(model, "agent_primary", ["slot": 1])
        let snapshot = try surfaceValue(surfaceCall(model, "surface_agent_snapshot", ["instance_id": "agent"]))
        #expect(snapshot.value(for: "slots")?.arrayValue?.first?.value(for: "state") == .string("queued"))
        let spoof = try surfaceCall(model, "surface_agent_primary", ["instance_id": "agent", "slot": 1, "origin": "interface"])
        #expect(spoof["isError"] as? Bool == true)
        #expect(try surfaceValue(spoof).value(for: "code") == .string("invalidParameter"))
        clock.time += 3
        model.advanceAgents()
        #expect(model.agents.slots[0].phase == .waitingApproval)
        let approval = try surfaceCall(model, "surface_agent_primary", ["instance_id": "agent", "slot": 1])
        #expect(try surfaceValue(approval).value(for: "code") == .string("permissionDenied"))
        #expect(model.agents.slots[0].phase == .waitingApproval)
        model.agentPrimary(1)
        let approved = try surfaceValue(surfaceCall(model, "surface_agent_snapshot", ["instance_id": "agent"]))
        #expect(approved.value(for: "slots")?.arrayValue?.first?.value(for: "state") == .string("running"))
    }

    @Test @MainActor func optionalRemoteToolsCannotForgeOutputTelemetryOrBypassEnablePolicy() throws {
        let model = ConsoleModel(startsMIDI: false)
        model.installOptionalPlugins(Set(OptionalBusinessPlugin.allCases))
        model.mcpWritesAllowed = true
        for descriptor in model.plugins.remoteTools {
            #expect(descriptor.outputSchema.value(for: "type") == .string("object"))
        }
        let capabilities = try surfaceValue(surfaceCall(model, "surface_capabilities"))
        #expect(capabilities.value(for: "instances")?.arrayValue?.count == 4)
        let denied = try surfaceCall(model, "surface_output_enable", ["instance_id": "output"])
        #expect(denied["isError"] as? Bool == true)
        #expect(try surfaceValue(denied).value(for: "code") == .string("permissionDenied"))
        let forged = try surfaceCall(model, "surface_output_enable", ["instance_id": "output", "actual": 1, "heartbeat": model.runtimeTime])
        #expect(try surfaceValue(forged).value(for: "code") == .string("invalidParameter"))
        #expect(model.trustedOSCActual == nil && model.trustedOSCHeartbeat == nil)
        #expect(!model.oscEnabled && model.mock.faders.allSatisfy { $0 == 0 })
        for name in ["surface_robot_trace", "surface_chassis_trace"] {
            let id = name.contains("robot") ? "robot" : "chassis"
            let response = try surfaceCall(model, name, ["instance_id": id])
            #expect(response["structuredContent"] != nil)
            #expect(try surfaceValue(response).value(for: "samples") == .array([]))
        }
        for name in ["surface_robot_snapshot", "surface_chassis_snapshot"] {
            let id = name.contains("robot") ? "robot" : "chassis"
            let result = try surfaceValue(surfaceCall(model, name, ["instance_id": id]))
            #expect(result.value(for: "actual") == .null)
            #expect(result.value(for: "metadata")?.value(for: "initialized") == .bool(false))
        }
    }
#endif
