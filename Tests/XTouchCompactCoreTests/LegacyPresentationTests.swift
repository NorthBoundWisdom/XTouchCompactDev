import Foundation
import SurfaceDeviceContracts
import Testing
@testable import XTouchCompactCore

@Test func presentationKeysUseRawUnicodeOrderMultiplicityAndNilTags() {
    let audit = CompactContextAudit()
    let composed = "\u{e9}", decomposed = "e\u{301}"
    #expect(composed == decomposed) // Swift's semantic equality is deliberately insufficient.
    let arrays = [[composed], [decomposed], ["a", "bc"], ["ab", "c"], ["nil"], ["unknown"], ["", "a"], ["a", ""], ["a", "a"], ["a"]]
    for array in arrays {
        #expect(audit.display(array).utf8.elementsEqual(String(reflecting: array).utf8))
    }
    #expect(audit.presentationMetrics["formats"] == arrays.count)
    let numbers = [[1, 2], [2, 1], [1, 1], [1], [], [Int.min, Int.max]]
    for array in numbers {
        #expect(audit.display(array).utf8.elementsEqual(String(reflecting: array).utf8))
    }
    #expect(audit.presentationMetrics["formats"] == arrays.count + numbers.count)
    let absent: CompactResourceScope? = nil
    let unknown = CompactResourceScope()
    #expect(audit.display(absent).utf8.elementsEqual(String(reflecting: absent).utf8))
    #expect(audit.display(unknown).utf8.elementsEqual(String(reflecting: Optional(unknown)).utf8))
    #expect(audit.presentationMetrics["formats"] == arrays.count + numbers.count + 2)
}

@Test func presentationScopeKeyMissesForEveryFieldAndEveryEndpointField() throws {
    #expect(Mirror(reflecting: CompactResourceScope()).children.compactMap(\.label) ==
        ["hostLayer", "source", "endpoint", "transmitChannel", "receiveChannel", "lightProtocol", "bindingGeneration", "authorizationRouteGeneration"])
    let endpointShape = try EndpointProvenance(endpointID: nil, deviceID: nil, connectionGeneration: 0, transportOrigin: .unknown)
    #expect(Mirror(reflecting: endpointShape).children.compactMap(\.label) == ["endpointID", "deviceID", "connectionGeneration", "transportOrigin"])
    var base = CompactResourceScope()
    base.source = .simulation
    base.endpoint = try .init(endpointID: "input", deviceID: "device", connectionGeneration: 5, transportOrigin: .localVirtual)
    var variants: [CompactResourceScope] = [base]
    func changed(_ body: (inout CompactResourceScope) throws -> Void) rethrows {
        var value = base; try body(&value); variants.append(value)
    }
    changed { $0.hostLayer = .b }
    changed { $0.source = nil }
    changed { $0.source = .hardware }
    changed { $0.endpoint = nil }
    try changed { $0.endpoint = try .init(endpointID: nil, deviceID: "device", connectionGeneration: 5, transportOrigin: .localVirtual) }
    try changed { $0.endpoint = try .init(endpointID: "other", deviceID: "device", connectionGeneration: 5, transportOrigin: .localVirtual) }
    try changed { $0.endpoint = try .init(endpointID: "input", deviceID: nil, connectionGeneration: 5, transportOrigin: .localVirtual) }
    try changed { $0.endpoint = try .init(endpointID: "input", deviceID: "other", connectionGeneration: 5, transportOrigin: .localVirtual) }
    try changed { $0.endpoint = try .init(endpointID: "input", deviceID: "device", connectionGeneration: UInt64.max, transportOrigin: .localVirtual) }
    try changed { $0.endpoint = try .init(endpointID: "input", deviceID: "device", connectionGeneration: 5, transportOrigin: .remoteVirtual) }
    changed { $0.transmitChannel = 3 }
    changed { $0.receiveChannel = 4 }
    changed { $0.lightProtocol = "\u{e9}" }
    changed { $0.lightProtocol = "e\u{301}" }
    changed { $0.bindingGeneration = UInt64.max }
    changed { $0.authorizationRouteGeneration = UInt64.max }
    let audit = CompactContextAudit()
    for value in variants {
        #expect(audit.display(value).utf8.elementsEqual(String(reflecting: Optional(value)).utf8))
    }
    #expect(audit.presentationMetrics["formats"] == variants.count)
    for value in variants {
        _ = audit.display(value)
    }
    #expect(audit.presentationMetrics["formats"] == variants.count)
    #expect(audit.presentationMetrics["hits"] == variants.count)
}

@Test func presentationMutationKeyIncludesCaseIdentifierPayloadAndAllNumericBits() {
    let audit = CompactContextAudit()
    let scope = CompactResourceScope()
    let mutations: [CompactResourceMutation] = [.removeAll, .remove(id: 1), .remove(id: 2), .upsert(id: 1, scope: scope, value: nil),
                                                .upsert(id: 1, scope: scope, value: "nil"), .upsert(id: 1, scope: scope, value: "unknown"),
                                                .upsert(id: 1, scope: scope, value: "0.0"), .upsert(id: 1, scope: scope, value: "-0.0"),
                                                .upsert(id: 1, scope: scope, value: "\u{e9}"), .upsert(id: 1, scope: scope, value: "e\u{301}")]
    for value in mutations {
        #expect(audit.display(value).utf8.elementsEqual(String(reflecting: value).utf8))
    }
    #expect(audit.presentationMetrics["formats"] == mutations.count)
    // No cached scope field is floating-point. Exercise the same full-bit key primitive
    // explicitly so a future DTO cannot silently canonicalize zero or NaN payloads.
    let doubles = [Double(0), -Double(0), Double(bitPattern: 0x7FF8_0000_0000_0001), Double(bitPattern: 0x7FF8_0000_0000_0002)]
    for value in doubles {
        var key = LegacyDisplayKey(kind: 128); key.uint(value.bitPattern)
        let text = audit.presentation(key: key.data) { String(reflecting: value) }
        #expect(text.utf8.elementsEqual(String(reflecting: value).utf8))
    }
    #expect(audit.presentationMetrics["formats"] == mutations.count + doubles.count)
}

@Test func presentationHitsPreserveEveryComparisonAndCapacityOnlyDisablesReuse() {
    let audit = CompactContextAudit()
    for _ in 0 ..< 100 {
        audit.compare("same-input", input: "input", native: audit.display([1, 2]), candidate: audit.display([1, 2]))
    }
    #expect(audit.comparisons.count == 100 && audit.comparisons.allSatisfy(\.matches))
    #expect(audit.presentationMetrics["requests"] == 200 && audit.presentationMetrics["formats"] == 1)
    #expect(audit.presentationMetrics["hits"] == 199)
    let bounded = CompactContextAudit()
    for value in 0 ... 1024 {
        #expect(bounded.display([value]) == String(reflecting: [value]))
    }
    #expect(bounded.presentationMetrics["entries"] == 1024)
    #expect(bounded.presentationMetrics["formats"] == 1025)
    _ = bounded.display([1024])
    #expect(bounded.presentationMetrics["formats"] == 1026) // Uncached still formats and compares.
}
