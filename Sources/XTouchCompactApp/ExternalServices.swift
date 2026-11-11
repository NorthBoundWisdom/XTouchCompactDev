#if os(macOS)
    import AppKit
    import Foundation
    import Network
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
            let tools: [[String: Any]] = [
                ["name": "get_state", "description": "Read active layer, parameters and physical touch state.", "inputSchema": ["type": "object", "properties": [:], "additionalProperties": false]],
                ["name": "set_parameter", "description": "Write a parameter; touched faders defer motors until release.", "inputSchema": ["type": "object", "properties": ["id": ["type": "string"], "value": ["type": "number"]], "required": ["id", "value"], "additionalProperties": false]],
                ["name": "agent_primary", "description": "Start or interrupt a Mock Agent slot. Approval requires the user interface.", "inputSchema": ["type": "object", "properties": ["slot": ["type": "integer", "minimum": 1, "maximum": 8]], "required": ["slot"], "additionalProperties": false]],
            ]
            if request["method"] as? String == "tools/list" {
                return ["tools": tools]
            }
            guard request["method"] as? String == "tools/call" else { throw MCPError.methodNotFound }
            guard let params = request["params"] as? [String: Any], let name = params["name"] as? String else { throw MCPError.unknownTool }
            defer { logAgentCall(name) }
            guard params["arguments"] == nil || params["arguments"] is [String: Any] else { throw MCPError.invalidRequest }
            let args = params["arguments"] as? [String: Any] ?? [:]
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

        func setOSCEnabled(_ enabled: Bool) {
            if !enabled {
                oscTransport.stop(); oscGate.setEnabled(false, now: runtimeTime)
                if oscEnabled {
                    oscEnabled = false
                }
                return
            }
            guard !oscEnabled else { return }
            guard !oscHost.isEmpty, oscPort > 0, session.parameters.definition(oscParameter) != nil else {
                oscFault("OSC output stopped: destination or parameter is invalid."); return
            }
            do {
                try oscTransport.start(host: oscHost, port: oscPort) { [weak self] error in
                    self?.oscFault("OSC output stopped: transport failure."); self?.serviceError(error)
                }
                let time = runtimeTime
                oscGate.setEnabled(false, now: time)
                oscGate.setEnabled(true, now: time)
                oscEnabled = true
            } catch { oscFault("OSC output stopped: transport failure."); serviceError(error) }
        }

        func tickOSC() {
            guard oscEnabled else { return }
            let time = runtimeTime
            guard let value = session.parameters.values[oscParameter], let definition = session.parameters.definition(oscParameter) else {
                oscFault("OSC output stopped: destination or parameter is invalid."); return
            }
            guard let output = oscGate.sample((value - definition.minimum) / (definition.maximum - definition.minimum), now: time) else {
                oscFault("OSC output stopped: scheduler heartbeat expired or safety gate tripped."); return
            }
            // sample validates the elapsed interval against the previous heartbeat first.
            // Only a timely scheduler tick refreshes liveness; a constant value is valid.
            oscGate.beat(now: time)
            do {
                try oscTransport.send(OSCCodec.encode(address: "/xtouch/value", value: Float(output)))
                if oscOutput != output {
                    oscOutput = output
                }
            } catch { oscFault("OSC output stopped: transport failure."); serviceError(error) }
        }

        private func oscFault(_ key: String) {
            setOSCEnabled(false)
            notificationsForOSC(key)
        }
    }
#endif
