import Foundation
import SurfacePluginContracts

public struct MCPToolFailure: Error, LocalizedError, Equatable, Sendable {
    public let reason: String
    public init(_ reason: String) {
        self.reason = reason
    }

    public var errorDescription: String? {
        reason
    }
}

public struct MCPAuditEntry: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let time: Date
    public let method: String
    public let succeeded: Bool
    public init(id: UUID = UUID(), time: Date, method: String, succeeded: Bool) {
        self.id = id
        self.time = time; self.method = method; self.succeeded = succeeded
    }
}

public struct MCPParameterWrite: Equatable, Sendable {
    public let id: String
    public let value: Double
    public init(id: String, value: Double) {
        self.id = id; self.value = value
    }
}

/// Host-independent input validation and BCR-aligned schemas. No device or UI access.
public enum ConsoleMCPTool: String, CaseIterable, Sendable {
    case listParameters = "list_parameters", getParameter = "get_parameter", setParameters = "set_parameters"
    case listControls = "list_controls", getStatus = "get_status", resetGroup = "reset_group"
    case getAgents = "get_agents", startAgent = "start_agent", interruptAgent = "interrupt_agent"
    case stopAllAgents = "stop_all_agents", listMIDIEndpoints = "list_midi_endpoints"

    public var isReadOnly: Bool {
        switch self {
        case .setParameters, .resetGroup, .startAgent, .interruptAgent, .stopAllAgents: false
        default: true
        }
    }

    public var inputSchema: JSONValue {
        let string: JSONValue = .object(["type": .string("string")])
        return switch self {
        case .getParameter: Self.schema(["id": string], required: ["id"])
        case .resetGroup: Self.schema(["group": string], required: ["group"])
        case .startAgent, .interruptAgent:
            Self.schema(["slot": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(8)])], required: ["slot"])
        case .setParameters:
            Self.schema(["values": .object([
                "type": .string("array"), "minItems": .number(1), "maxItems": .number(256),
                "items": Self.schema(["id": string, "value": .object(["type": .string("number")])], required: ["id", "value"]),
            ])], required: ["values"])
        default: Self.schema([:])
        }
    }

    public var definition: JSONValue {
        .object([
            "name": .string(rawValue), "description": .string(rawValue), "inputSchema": inputSchema,
            "outputSchema": .object(["type": .string("object"), "properties": .object(["data": .object([:])]), "required": .array([.string("data")])]),
            "annotations": .object(["readOnlyHint": .bool(isReadOnly), "openWorldHint": .bool(self == .startAgent)]),
        ])
    }

    private static func schema(_ fields: [String: JSONValue], required: [String] = []) -> JSONValue {
        .object(["type": .string("object"), "properties": .object(fields), "required": .array(required.map(JSONValue.string)), "additionalProperties": .bool(false)])
    }

    public func validate(_ arguments: JSONValue) throws -> [String: JSONValue] {
        guard let args = arguments.objectValue else { throw MCPToolFailure("arguments must be an object") }
        let required: Set<String> = switch self {
        case .getParameter: ["id"]
        case .resetGroup: ["group"]
        case .startAgent, .interruptAgent: ["slot"]
        case .setParameters: ["values"]
        default: []
        }
        guard Set(args.keys) == required else { throw MCPToolFailure("Missing or unknown tool arguments") }
        switch self {
        case .getParameter: _ = try Self.string(args, "id")
        case .resetGroup: _ = try Self.string(args, "group")
        case .startAgent, .interruptAgent:
            guard let slot = args["slot"]?.exactIntValue, (1 ... 8).contains(slot) else { throw MCPToolFailure("slot must be an integer from 1 to 8") }
        case .setParameters: _ = try Self.writes(args)
        default: break
        }
        return args
    }

    public static func string(_ args: [String: JSONValue], _ key: String) throws -> String {
        guard let value = args[key]?.stringValue, value.utf8.count <= 1024 else { throw MCPToolFailure("Expected a string of at most 1024 bytes") }
        return value
    }

    public static func writes(_ args: [String: JSONValue]) throws -> [MCPParameterWrite] {
        guard let values = args["values"]?.arrayValue, (1 ... 256).contains(values.count) else { throw MCPToolFailure("values must contain 1–256 parameters") }
        var seen = Set<String>()
        return try values.map { entry in
            guard let object = entry.objectValue, Set(object.keys) == ["id", "value"],
                  let value = object["value"]?.finiteNumber else { throw MCPToolFailure("Each value must contain id and a finite number") }
            let id = try string(object, "id")
            guard seen.insert(id).inserted else { throw MCPToolFailure("Batch contains duplicate parameters") }
            return MCPParameterWrite(id: id, value: value)
        }
    }

    public static func result(_ value: JSONValue, isError: Bool = false) throws -> JSONValue {
        let content: JSONValue = .object(["data": value])
        return try .object(["content": .array([.object(["type": .string("text"), "text": .string(content.jsonText)])]),
                            "structuredContent": content, "isError": .bool(isError)])
    }
}
