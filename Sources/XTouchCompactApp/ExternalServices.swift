#if os(macOS)
    import AppKit
    import Foundation
    import Network
    import OutputRemoteBinding
    import RemoteToolContracts
    import SurfacePluginContracts
    import XTouchCompactCore

    extension ConsoleModel {
        func setMCPEnabled(_ enabled: Bool) {
            if !enabled {
                mcp.stop(); mcpEnabled = false; return
            }
            do {
                let token = try accessToken()
                mcp.handler = { [weak self] request in
                    guard let self else { throw MCPError.denied }
                    return try routeMCP(request)
                }
                mcp.onError = { [weak self] error in self?.serviceError(error) }
                try mcp.start(port: mcpPort, token: token)
                mcpEnabled = true
            } catch { serviceError(error) }
        }

        func copyMCPToken() {
            do {
                let token = try accessToken()
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(token, forType: .string)
            } catch { serviceError(error) }
        }

        func routeMCP(_ request: [String: Any]) throws -> [String: Any] {
            var tools: [[String: Any]] = [
                ["name": "get_state", "description": "Read active layer, parameters and physical touch state.", "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]],
                ["name": "set_parameter", "description": "Write a parameter; touched faders defer motors until release.", "inputSchema": ["type": "object", "properties": ["id": ["type": "string"], "value": ["type": "number"]], "required": ["id", "value"], "additionalProperties": false]],
                ["name": "agent_primary", "description": "Start or interrupt a Mock Agent slot. Approval requires the user interface.", "inputSchema": ["type": "object", "properties": ["slot": ["type": "integer", "minimum": 1, "maximum": 8]], "required": ["slot"], "additionalProperties": false]],
            ]
            tools += try plugins.remoteTools.map { tool in
                try ["name": tool.name, "description": "Shared business plugin operation: " + tool.name,
                     "inputSchema": JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.inputSchema)),
                     "outputSchema": JSONSerialization.jsonObject(with: JSONEncoder().encode(tool.outputSchema)),
                     "annotations": ["readOnlyHint": !tool.isMutation]]
            }
            if request["method"] as? String == "tools/list" {
                return ["tools": tools]
            }
            guard request["method"] as? String == "tools/call" else { throw MCPError.methodNotFound }
            guard let params = request["params"] as? [String: Any], let name = params["name"] as? String else { throw MCPError.unknownTool }
            defer { logAgentCall(name) }
            guard params["arguments"] == nil || params["arguments"] is [String: Any] else { throw MCPError.invalidRequest }
            let args = params["arguments"] as? [String: Any] ?? [:]
            if plugins.remoteTools.contains(where: { $0.name == name }) {
                do {
                    guard let data = try? JSONSerialization.data(withJSONObject: args),
                          let arguments = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw RemoteFailure(code: "invalidParameter") }
                    return try surfaceMCPContent(performSurfaceCall(name, arguments: arguments), isError: false)
                } catch {
                    return try surfaceMCPContent(.encoded(RemoteFailure.from(error)), isError: true)
                }
            }
            var result: [String: Any] = [:]
            switch name {
            case "get_state":
                guard args.isEmpty else { throw MCPError.invalidRequest }
                result = try ["layer": layer.rawValue, "values": session.parameters.values,
                              "parameters": JSONSerialization.jsonObject(with: JSONEncoder().encode(session.parameters.configuration.parameters)),
                              "layerMismatch": session.state.layerMismatch,
                              "observedLayer": session.state.observedLayer?.rawValue ?? "unknown",
                              "touchedFaders": (1 ... 9).filter { session.state.isTouched($0) },
                              "pendingMotors": (1 ... 9).filter { session.state.isMotorPending($0) }]
            case "set_parameter":
                guard mcpWritesAllowed, Set(args.keys) == ["id", "value"], let id = args["id"] as? String,
                      let value = args["value"] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite else { throw MCPError.denied }
                try applyAgentParameter(id, value: value.doubleValue)
                result = ["value": session.parameters.values[id]!, "deferredFaders": (1 ... 9).filter { session.state.isMotorPending($0) }]
            case "agent_primary":
                guard mcpWritesAllowed, Set(args.keys) == ["slot"], let number = args["slot"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue,
                      (1 ... 8).contains(number.intValue) else { throw MCPError.denied }
                let slot = number.intValue
                do { try performPluginAction(PluginConfigurationAdapter.agentAction(slot), origin: .remote) }
                catch { throw MCPError.denied }
                result = ["phase": agents.slots[slot - 1].phase.rawValue]
            default: throw MCPError.unknownTool
            }
            let text = try String(data: JSONSerialization.data(withJSONObject: result, options: .sortedKeys), encoding: .utf8)!
            return ["content": [["type": "text", "text": text]], "isError": false]
        }

        private func surfaceMCPContent(_ value: JSONValue, isError: Bool) throws -> [String: Any] {
            var response: [String: Any] = try ["content": [["type": "text", "text": value.jsonText]], "isError": isError]
            if value.objectValue != nil {
                response["structuredContent"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
            }
            return response
        }

        func setOSCEnabled(_ enabled: Bool) {
            let time = runtimeTime
            if !enabled {
                oscTransport.stop()
                if var binding = plugins.binding(OutputRemoteBinding.defaultInstanceID, as: OutputRemoteBinding.self) {
                    do {
                        try binding.plugin.setEnabled(false)
                        _ = binding.plugin.evaluate(targets: [:], at: time)
                        binding.plugin.setConnected(false, at: time)
                        var next = plugins
                        try next.replaceBinding(binding, at: time, event: .init(code: "output.disabled"))
                        try commitPlugins(next)
                    } catch { serviceError(error) }
                }
                clearTrustedOSCTelemetry()
                if oscEnabled {
                    oscEnabled = false
                }
                return
            }
            guard !oscEnabled else { return }
            guard !oscHost.isEmpty, oscPort > 0, session.parameters.definition(oscParameter) != nil else {
                oscFault("OSC output stopped: destination or parameter is invalid."); return
            }
            guard let actual = trustedOSCActual, actual.value.isFinite,
                  let heartbeat = trustedOSCHeartbeat, time >= actual.time, time - actual.time < 0.3,
                  time >= heartbeat, time - heartbeat < 0.3
            else {
                oscFault("OSC output stopped: trusted actual state and an independent heartbeat are required."); return
            }
            if plugins.binding(OutputRemoteBinding.defaultInstanceID, as: OutputRemoteBinding.self) == nil {
                installOptionalPlugins([.output])
            }
            guard var binding = plugins.binding(OutputRemoteBinding.defaultInstanceID, as: OutputRemoteBinding.self) else { return }
            do {
                try oscTransport.start(host: oscHost, port: oscPort) { [weak self] error in
                    self?.oscFault("OSC output stopped: transport failure."); self?.serviceError(error)
                }
                binding.plugin.setConnected(true, at: time)
                binding.plugin.receiveHeartbeat(at: heartbeat)
                binding.plugin.receiveActual([.init(id: "output.value", value: actual.value, receivedAt: actual.time)])
                try binding.plugin.setEnabled(false)
                _ = binding.plugin.evaluate(targets: [:], at: time)
                try binding.plugin.setEnabled(true)
                let decision = binding.plugin.evaluate(targets: ["output.value": actual.value], at: time)
                guard decision.command?.enabled == true else {
                    oscFault(oscSafetyMessage(decision.reason, fallback: "OSC output stopped: trusted actual state and an independent heartbeat are required.")); return
                }
                var next = plugins
                try next.replaceBinding(binding, at: time, event: .init(code: "output.enabled"))
                try commitPlugins(next)
                oscEnabled = true
            } catch { oscFault("OSC output stopped: transport failure."); serviceError(error) }
        }

        func tickOSC() {
            guard oscEnabled else { return }
            let time = runtimeTime
            guard let value = session.parameters.values[oscParameter], let definition = session.parameters.definition(oscParameter),
                  var binding = plugins.binding(OutputRemoteBinding.defaultInstanceID, as: OutputRemoteBinding.self)
            else {
                oscFault("OSC output stopped: destination or parameter is invalid."); return
            }
            let previous = binding.plugin.decision
            let decision = binding.plugin.evaluate(targets: ["output.value": (value - definition.minimum) / (definition.maximum - definition.minimum)], at: time)
            let changed = previous?.status != decision.status || previous?.reason != decision.reason || previous?.parameterID != decision.parameterID || previous?.limited != decision.limited
            let event: PluginEvent? = changed ? .init(code: "output.evaluated", fields: ["status": .string(decision.status.rawValue), "reasonKey": .string(decision.reason), "parameterID": decision.parameterID.map { .string($0.rawValue) } ?? .null, "limited": .bool(decision.limited)]) : nil
            do {
                var next = plugins
                try next.replaceBinding(binding, at: time, event: event)
                try commitPlugins(next)
                guard let command = decision.command, command.enabled, let output = command.values["output.value"] else {
                    oscFault(oscSafetyMessage(decision.reason, fallback: "OSC output stopped: actual feedback or independent heartbeat is missing, stale, or requires rearming.")); return
                }
                try oscTransport.send(OSCCodec.encode(address: "/xtouch/value", value: Float(output)))
                if oscOutput != output {
                    oscOutput = output
                }
            } catch { oscFault("OSC output stopped: transport failure."); serviceError(error) }
        }

        private func oscSafetyMessage(_ reason: String, fallback: String) -> String {
            reason == "output.actual_not_float32_representable"
                ? "OSC output stopped: actual feedback precision cannot be used safely for OSC."
                : fallback
        }

        private func oscFault(_ key: String) {
            setOSCEnabled(false)
            notificationsForOSC(key)
        }
    }
#endif
