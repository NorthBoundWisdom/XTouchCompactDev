import Foundation
import Testing
@testable import XTouchCompactCore

@Test func hardwareValueCacheSeparatesLayersAndNeverRestoresTouchOrCommands() throws {
    let map = try FactoryStandardMap()
    let date = Date(timeIntervalSince1970: 100)
    var cache = HardwareValueCache(inputID: 42, transmitChannel: 0)
    for message: MIDIMessage in [
        .controlChange(channel: 0, number: 1, value: 80),
        .controlChange(channel: 0, number: 10, value: 20),
        .controlChange(channel: 0, number: 37, value: 90),
        .controlChange(channel: 0, number: 111, value: 127),
        .noteOn(channel: 0, number: 71, velocity: 127),
    ] {
        try cache.record(#require(map.decode(message)), at: date)
    }
    #expect(cache.faders[1]?.value == 80)
    #expect(cache.encoders[.a]?[1]?.value == 20)
    #expect(cache.encoders[.b]?[1]?.value == 90)
    #expect(cache.faders.count == 1)
    #expect(cache.lastInputLayer == .b)
    #expect(cache.encoders[.b]?[1]?.timestamp == date)
    try cache.validate()
    let roundTrip = try JSONDecoder().decode(HardwareValueCache.self, from: JSONEncoder().encode(cache))
    #expect(roundTrip == cache)
    cache.invalidateFader(1)
    #expect(cache.faders[1] == nil)
    #expect(roundTrip.faders[1]?.value == 80) // Invalidation cannot mutate saved history.
}

@Test func workspaceRemainsCompatibleWithoutReadingHistoryAndRejectsInvalidCache() throws {
    let workspace = SavedWorkspace(configuration: .neutral, profile: .init())
    let data = try JSONEncoder().encode(workspace)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object.removeValue(forKey: "hardwareValues")
    let legacy = try JSONDecoder().decode(SavedWorkspace.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(legacy.hardwareValues == nil)
    try legacy.validate()
    var withCache = workspace
    withCache.hardwareValues = HardwareValueCache(inputID: 42, transmitChannel: 16)
    #expect(throws: HardwareValueCacheError.self) { try withCache.validate() }
    var cache = HardwareValueCache(inputID: 42, transmitChannel: 0)
    cache.record(CompactInput(control: .fader(1), layer: .a, value: 255), at: Date())
    #expect(cache.faders.isEmpty)
}
