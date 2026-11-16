import Foundation
import SurfacePluginContracts
import Testing
@testable import XTouchCompactCore

@Test func consoleMCPSchemasHaveStrictInputsAndBCRResultEnvelope() throws {
    #expect(ConsoleMCPTool.allCases.count == 11)
    #expect(Set(ConsoleMCPTool.allCases.map(\.rawValue)).count == 11)
    for tool in ConsoleMCPTool.allCases {
        #expect(tool.inputSchema.value(for: "additionalProperties") == .bool(false))
        #expect(throws: MCPToolFailure.self) { _ = try tool.validate(.object(["origin": .string("interface")])) }
        #expect(throws: MCPToolFailure.self) { _ = try tool.validate(.array([])) }
    }
    for tool in [ConsoleMCPTool.startAgent, .interruptAgent] {
        for slot: JSONValue in [.bool(true), .double(1.5), .number(0), .number(9), .string("1")] {
            #expect(throws: MCPToolFailure.self) { _ = try tool.validate(.object(["slot": slot])) }
        }
        #expect(try tool.validate(.object(["slot": .number(1)]))["slot"] == .number(1))
    }
    let result = try ConsoleMCPTool.result(.array([.number(1)]))
    let text = try #require(result.value(for: "content")?.arrayValue?.first?.value(for: "text")?.stringValue)
    #expect(try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) == result.value(for: "structuredContent"))
    #expect(result.value(for: "structuredContent") == .object(["data": .array([.number(1)])]))
}

@Test func consoleMCPBatchValidationRejectsDuplicatesExtraFieldsAndInvalidNumbers() throws {
    let entry: JSONValue = .object(["id": .string("p"), "value": .number(1)])
    for values in [[], [entry, entry], [.object(["id": .string("p"), "value": .bool(true)])],
                   [.object(["id": .string("p"), "value": .number(1), "origin": .string("interface")])],
                   [.object(["id": .string("p"), "value": .double(.infinity)])], Array(repeating: entry, count: 257)]
    {
        #expect(throws: MCPToolFailure.self) { _ = try ConsoleMCPTool.setParameters.validate(.object(["values": .array(values)])) }
    }
    #expect(try ConsoleMCPTool.writes(["values": .array([entry])]).first?.value == 1)
}
