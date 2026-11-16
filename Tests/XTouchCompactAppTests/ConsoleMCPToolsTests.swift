#if os(macOS)
    import Foundation
    import SurfacePluginContracts
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @MainActor private func call(_ model: ConsoleModel, _ name: String, _ args: [String: Any] = [:], fails: Bool = false) throws -> JSONValue {
        let response = try model.routeMCP(["method": "tools/call", "params": ["name": name, "arguments": args]])
        #expect(response["isError"] as? Bool == fails)
        let structured = try #require(response["structuredContent"])
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONSerialization.data(withJSONObject: structured))
        let content = try #require(response["content"] as? [[String: Any]])
        let text = try #require(content.first?["text"] as? String)
        #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == value)
        return try #require(value.value(for: "data"))
    }

    @Test @MainActor func consoleMCPReadToolsAreTruthfulAndCannotChangeConnections() throws {
        let clock = TestClock()
        let model = ConsoleModel(startsMIDI: false, now: { clock.date }, isolated: true)
        let list = try model.routeMCP(["method": "tools/list"])["tools"] as? [[String: Any]] ?? []
        let names = Set(list.compactMap { $0["name"] as? String })
        #expect(Set(ConsoleMCPTool.allCases.map(\.rawValue)).isSubset(of: names))
        #expect(!names.contains("set_device_source") && !names.contains("set_midi_endpoints"))
        #expect(try call(model, "list_controls").arrayValue?.count == 89)
        #expect(try call(model, "list_parameters").arrayValue?.count == 50)
        let parameter = try call(model, "get_parameter", ["id": "a.Fader.1"])
        #expect(parameter.value(for: "actualValue") == .null && parameter.value(for: "writable") == .bool(false))
        #expect(try call(model, "get_status").value(for: "source") == .string("mock"))
        #expect(try call(model, "get_status").value(for: "droppedFeedbackCount") == .null)
        model.inputChoice = 999 // Unapplied edit must not be represented as saved selection.
        #expect(try call(model, "list_midi_endpoints").value(for: "selection")?.value(for: "sourceID") == .null)
        #expect(try call(model, "get_agents").value(for: "slots")?.arrayValue?.count == 8)
        #expect(!model.hardwareMode && !model.mcpWritesAllowed && !model.mcpAgentControlAllowed)
    }

    @Test @MainActor func consoleMCPBatchIsAtomicOnInvalidProtectedAndQuotaFailures() throws {
        let clock = TestClock()
        let model = ConsoleModel(startsMIDI: false, now: { clock.date })
        let batch: [String: Any] = ["values": [["id": "a.Fader.1", "value": 90], ["id": "missing", "value": 10]]]
        _ = try call(model, "set_parameters", batch, fails: true)
        model.mcpWritesAllowed = true
        let before = model.session.parameters.values
        model.clearMonitor()
        _ = try call(model, "set_parameters", batch, fails: true)
        #expect(model.session.parameters.values == before)
        #expect(!model.events.contains { $0.direction == .output })
        var config = model.session.parameters.configuration
        config.parameters[1].agentWritable = false
        model.applyConfiguration(config)
        _ = try call(model, "set_parameters", ["values": [["id": "a.Fader.1", "value": 90], ["id": config.parameters[1].id, "value": 10]]], fails: true)
        #expect(model.session.parameters.values == before)
        for _ in 0 ..< 59 {
            _ = try call(model, "set_parameters", ["values": [["id": "a.Fader.1", "value": 0]]])
        }
        _ = try call(model, "set_parameters", ["values": [["id": "a.Fader.1", "value": 90], ["id": "a.Fader.3", "value": 10]]], fails: true)
        #expect(model.session.parameters.values == before)
        // Failed reservation did not consume the remaining member allowance.
        _ = try call(model, "set_parameters", ["values": [["id": "a.Fader.1", "value": 1]]])
        clock.time += 1
        _ = try call(model, "set_parameters", ["values": [["id": "a.Fader.1", "value": 90]]])
        #expect(model.bank.faders[0] == 90 && model.mock.faders[0] == 0)
    }

    @Test @MainActor func consoleMCPBatchAndResetKeepTouchAndDefaultOffMotorAuthorization() throws {
        for motors in [false, true] {
            let clock = TestClock()
            let model = ConsoleModel(startsMIDI: false, now: { clock.date })
            model.mcpWritesAllowed = true; model.mcpMotorWritesAllowed = motors
            model.touchFader(1, isTouched: true)
            model.clearMonitor()
            let result = try call(model, "set_parameters", ["values": [["id": "a.Fader.1", "value": 90]]])
            #expect(result.arrayValue?.first?.value(for: "motorsWithheld") == .array(motors ? [] : [.number(1)]))
            #expect(model.session.state.isMotorPending(1) == motors)
            #expect(!model.events.contains { $0.direction == .output && $0.control == .fader(1) })
            model.touchFader(1, isTouched: false)
            model.setParameter("a.Fader.1", value: 70)
            model.touchFader(1, isTouched: true)
            model.clearMonitor()
            clock.time += 1
            let reset = try call(model, "reset_group", ["group": "Layer A"])
            #expect(reset.value(for: "results")?.arrayValue?.count == 25)
            #expect(model.bank.faders[0] == 0)
            #expect(!model.events.contains { $0.direction == .output && $0.control == .fader(1) })
            model.touchFader(1, isTouched: false)
            #expect(model.mock.faders[0] == (motors ? 0 : 70))
            model.mcpWritesAllowed = false
            _ = try call(model, "reset_group", ["group": "Layer A"], fails: true)
        }
    }

    @Test @MainActor func consoleMCPResetReportsProtectedSkipsAndAgentToolsCannotApproveOrMoveMotors() throws {
        let clock = TestClock()
        let model = ConsoleModel(startsMIDI: false, now: { clock.date })
        var config = model.session.parameters.configuration
        config.parameters[0].agentWritable = false
        model.applyConfiguration(config)
        model.mcpWritesAllowed = true
        model.setParameter("a.Fader.1", value: 80)
        let reset = try call(model, "reset_group", ["group": "Layer A"])
        #expect(reset.value(for: "skipped")?.arrayValue?.first?.value(for: "id") == .string("a.Fader.1"))
        #expect(model.bank.faders[0] == 80)
        for motors in [false, true] {
            model.mcpMotorWritesAllowed = motors
            model.touchFader(1, isTouched: true)
            for name in ["start_agent", "interrupt_agent", "stop_all_agents"] {
                model.mcpAgentControlAllowed = false
                _ = try call(model, name, name == "stop_all_agents" ? [:] : ["slot": 1], fails: true)
            }
            model.mcpAgentControlAllowed = true
            clock.time += 1
            model.clearMonitor()
            _ = try call(model, "start_agent", ["slot": 1])
            _ = try call(model, "start_agent", ["slot": 1], fails: true)
            clock.time += 3; model.advanceAgents()
            #expect(model.agents.slots[0].phase == .waitingApproval)
            _ = try call(model, "start_agent", ["slot": 1], fails: true)
            #expect(model.agents.slots[0].phase == .waitingApproval)
            _ = try call(model, "interrupt_agent", ["slot": 1])
            _ = try call(model, "start_agent", ["slot": 2])
            _ = try call(model, "stop_all_agents")
            #expect(model.agents.slots[1].phase == .interrupted)
            #expect(!model.events.contains { $0.direction == .output && $0.control == .fader(1) })
            model.touchFader(1, isTouched: false)
        }
        for _ in 0 ..< 110 {
            _ = try call(model, "get_status")
        }
        #expect(model.panelSnapshot.mcpAudit.count == 100)
        #expect(model.panelSnapshot.mcpAudit.allSatisfy { $0.time == clock.date && $0.method == "get_status" })
        let grant = try #require(model.panelIntents.setMCPAgentControlAllowed)
        grant(false)
        #expect(!model.panelSnapshot.mcpAgentControlAllowed)
    }
#endif
