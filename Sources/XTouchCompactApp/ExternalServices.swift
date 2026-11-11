#if os(macOS)
    import AppKit
    import Foundation
    import Network
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
                try mcp.start(token: token)
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
                ["name": "agent_primary", "description": "Start, interrupt or approve a Mock Agent slot.", "inputSchema": ["type": "object", "properties": ["slot": ["type": "integer", "minimum": 1, "maximum": 8]], "required": ["slot"], "additionalProperties": false]],
            ]
            if request["method"] as? String == "tools/list" {
                return ["tools": tools]
            }
            guard request["method"] as? String == "tools/call", let params = request["params"] as? [String: Any], let name = params["name"] as? String else { throw MCPError.unknownTool }
            defer { logAgentCall(name) }
            let args = params["arguments"] as? [String: Any] ?? [:]
            var result: [String: Any] = [:]
            switch name {
            case "get_state":
                guard args.isEmpty else { throw MCPError.invalidRequest }
                result = try ["layer": layer.rawValue, "values": session.parameters.values,
                              "parameters": JSONSerialization.jsonObject(with: JSONEncoder().encode(session.parameters.configuration.parameters)),
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
                agentPrimary(slot, fromAgent: true); result = ["phase": agents.slots[slot - 1].phase.rawValue]
            default: throw MCPError.unknownTool
            }
            let text = try String(data: JSONSerialization.data(withJSONObject: result, options: .sortedKeys), encoding: .utf8)!
            return ["content": [["type": "text", "text": text]], "isError": false]
        }

        func setOSCEnabled(_ enabled: Bool) {
            let time = Date().timeIntervalSince1970
            if !enabled {
                oscConnection?.cancel(); oscConnection = nil; oscGate.setEnabled(false, now: time); oscEnabled = false; return
            }
            guard !oscHost.isEmpty, let port = NWEndpoint.Port(rawValue: oscPort), !oscParameter.isEmpty else { serviceError(OSCError.invalidAddress); return }
            oscGate.setEnabled(false, now: time)
            oscGate.setEnabled(true, now: time)
            let connection = NWConnection(host: NWEndpoint.Host(oscHost), port: port, using: .udp)
            oscConnection = connection
            connection.stateUpdateHandler = { [weak self] state in
                if case let .failed(error) = state {
                    Task { @MainActor in self?.setOSCEnabled(false); self?.serviceError(error) }
                }
            }
            connection.start(queue: .main); oscEnabled = true
        }

        func tickOSC() {
            guard oscEnabled else { return }
            let time = Date().timeIntervalSince1970
            // The app heartbeat is checked before refreshing, so a stalled UI trips the gate.
            guard let value = session.parameters.values[oscParameter], let definition = session.parameters.definition(oscParameter),
                  let output = oscGate.sample((value - definition.minimum) / (definition.maximum - definition.minimum), now: time)
            else {
                setOSCEnabled(false); return
            }
            oscGate.beat(now: time)
            do {
                let packet = try OSCCodec.encode(address: "/xtouch/value", value: Float(output))
                oscConnection?.send(content: packet, completion: .contentProcessed { [weak self] error in
                    if let error {
                        Task { @MainActor in self?.setOSCEnabled(false); self?.serviceError(error) }
                    }
                })
                oscOutput = output
            } catch { setOSCEnabled(false); serviceError(error) }
        }
    }
#endif
