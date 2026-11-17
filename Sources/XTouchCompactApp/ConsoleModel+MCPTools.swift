#if os(macOS)
    import Foundation
    import SurfacePluginContracts
    import XTouchCompactCore

    extension ConsoleModel {
        func callConsoleMCPTool(_ tool: ConsoleMCPTool, arguments: JSONValue) throws -> JSONValue {
            guard !rejectGUIVirtualEscape() else { throw GUIVirtualError.forbidden }
            let args = try tool.validate(arguments)
            switch tool {
            case .listParameters:
                return try .array(session.parameters.configuration.parameters.map { try mcpParameterInfo($0.id) })
            case .getParameter:
                return try mcpParameterInfo(ConsoleMCPTool.string(args, "id"))
            case .setParameters:
                return try .array(applyMCPBatch(ConsoleMCPTool.writes(args)))
            case .resetGroup:
                let group = try ConsoleMCPTool.string(args, "group")
                let members = session.parameters.configuration.parameters.filter { $0.group == group }
                guard !members.isEmpty else { throw MCPToolFailure("Unknown parameter group") }
                let writable = members.filter { $0.agentWritable && $0.externallyProtected != true }
                return try .object([
                    "results": .array(applyMCPBatch(writable.map { .init(id: $0.id, value: $0.defaultValue) })),
                    "skipped": .array(members.filter { !$0.agentWritable || $0.externallyProtected == true }.map {
                        .object(["id": .string($0.id), "reason": .string("Parameter is protected from Agent writes")])
                    }),
                ])
            case .listControls:
                let config = session.parameters.configuration
                let map = session.state.map
                return try .array(CompactInputGroup.allCases.flatMap(\.controls).map { control in
                    let assignment = config.assignments.first { $0.control == control && $0.layer == layer }
                    var value: JSONValue = .null
                    if case let .parameter(id) = assignment?.action {
                        value = session.parameters.values[id].map(JSONValue.double) ?? .null
                    }
                    func address(_ value: MIDIAddress?) -> JSONValue {
                        guard let value else { return .null }
                        return .object(["type": .string(value.messageType.rawValue), "channel": .number(Int(value.channel)), "number": .number(Int(value.number))])
                    }
                    return try .object([
                        "control": .encoded(control), "label": .string(control.description),
                        "assignment": assignment.map(JSONValue.encoded) ?? .null,
                        "binding": .object(["input": address(map.inputAddress(for: control, layer: layer)), "feedback": address(map.feedbackAddress(for: control))]),
                        "value": value,
                    ])
                })
            case .getStatus:
                return .object([
                    "source": .string(hardwareMode ? "hardware" : "mock"),
                    "connected": .bool(!hardwareMode || connection.isConnected),
                    "droppedFeedbackCount": .null,
                    "permissions": .object([
                        "parameterWrite": .bool(mcpWritesAllowed), "configurationWrite": .bool(false),
                        "agentControl": .bool(mcpAgentControlAllowed), "deviceControl": .bool(false),
                        "robotControl": .bool(false), "chassisControl": .bool(false),
                        "simulationControl": .bool(mcpSimulationControlAllowed), "writesPerSecond": .number(60),
                        "motorWrites": .bool(mcpMotorWritesAllowed),
                    ]),
                    "hardwareConnection": .object([
                        "connected": .bool(connection.isConnected),
                        "source": connection.connectedInput.map { .string($0.name) } ?? .null,
                        "destination": connection.connectedOutput.map { .string($0.name) } ?? .null,
                        "error": connection.error.map { .string($0.key) } ?? .null,
                    ]),
                    "configurationPersistenceError": notifications.first { $0.id == "storage" }?.message.map { .string($0.key) } ?? .null,
                    "layer": .string(layer.rawValue),
                    "touchedFaders": .array((1 ... 9).filter { session.state.isTouched($0) }.map(JSONValue.number)),
                    "pendingMotors": .array((1 ... 9).filter { session.state.isMotorPending($0) }.map(JSONValue.number)),
                ])
            case .listMIDIEndpoints:
                func list(_ endpoints: [CompactMIDIEndpoint]) -> JSONValue {
                    .array(endpoints.map { .object(["id": .number(Int($0.id)), "name": .string($0.name), "availabilityKnown": .bool(true)]) })
                }
                return .object([
                    "sources": list(connection.inputs), "destinations": list(connection.outputs),
                    "selection": mcpAppliedEndpointSelection,
                    "connectedSourceID": connection.connectedInput.map { .number(Int($0.id)) } ?? .null,
                    "connectedDestinationID": connection.connectedOutput.map { .number(Int($0.id)) } ?? .null,
                    "connectedSource": connection.connectedInput.map { .string($0.name) } ?? .null,
                    "connectedDestination": connection.connectedOutput.map { .string($0.name) } ?? .null,
                    "error": connection.error.map { .string($0.key) } ?? .null,
                ])
            case .getAgents:
                return .object(["backend": .string("mock"), "slots": .array(agents.slots.map {
                    .object(["id": .object(["rawValue": .number($0.id)]), "name": .string("Agent \($0.id)"),
                             "state": .string($0.phase.rawValue), "progress": .double($0.progress),
                             "statusText": .string($0.statusKey), "lastUpdated": .null])
                })])
            case .startAgent, .interruptAgent, .stopAllAgents:
                guard mcpWritesAllowed, mcpAgentControlAllowed else { throw MCPToolFailure("Agent control permission is disabled") }
                if tool == .stopAllAgents {
                    try consumeConsoleMCPWrites(1)
                    for slot in agents.slots where [.queued, .running, .waitingApproval].contains(slot.phase) {
                        try interruptMCPAgent(slot.id)
                    }
                } else {
                    let slot = args["slot"]!.exactIntValue!
                    if tool == .startAgent {
                        guard let current = agents.slots.first(where: { $0.id == slot }),
                              ![.queued, .running, .waitingApproval].contains(current.phase) else { throw MCPToolFailure("Agent is busy; remote approval is unavailable") }
                        try consumeConsoleMCPWrites(1)
                        try performPluginAction(PluginConfigurationAdapter.agentAction(slot), origin: .remote)
                    } else {
                        try consumeConsoleMCPWrites(1)
                        try interruptMCPAgent(slot)
                    }
                }
                return .object(["accepted": .bool(true)])
            }
        }

        private func mcpParameterInfo(_ id: String) throws -> JSONValue {
            guard let definition = session.parameters.definition(id), let value = session.parameters.values[id] else { throw MCPToolFailure("Unknown parameter") }
            return try .object([
                "id": .string(id), "name": .string(definition.name), "group": .string(definition.group), "unit": .string(definition.unit),
                "minimum": .double(definition.minimum), "maximum": .double(definition.maximum), "defaultValue": .double(definition.defaultValue),
                "kind": .string(definition.isSwitch ? "toggle" : "continuous"), "step": definition.step == 0 ? .null : .double(definition.step),
                "agentWritable": .bool(definition.agentWritable), "externallyProtected": .bool(definition.externallyProtected == true),
                "value": .double(value), "actualValue": .null, "outputValue": .null,
                "writable": .bool(mcpWritesAllowed && definition.agentWritable && definition.externallyProtected != true),
                "controls": .array(session.parameters.configuration.assignments.filter {
                    if case .parameter(id) = $0.action {
                        return true
                    }; return false
                }.map { try .encoded($0) }),
            ])
        }
    }
#endif
