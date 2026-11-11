import Foundation
import Testing
@testable import XTouchCompactCore

@Test func oscPacketAndSafetyGate() throws {
    #expect(try OSCCodec.encode(address: "/x", value: 1) == Data([47, 120, 0, 0, 44, 102, 0, 0, 63, 128, 0, 0]))
    #expect(throws: OSCError.self) { _ = try OSCCodec.encode(address: "x", value: 1) }
    #expect(throws: OSCError.self) { _ = try OSCCodec.encode(address: "/x", value: .nan) }
    var gate = try MotionSafetyGate()
    gate.setEnabled(true, now: 0)
    #expect(!gate.enabled)
    gate.setEnabled(false, now: 0); gate.setEnabled(true, now: 0)
    #expect(gate.sample(10, now: 0.5) == 0.125)
    gate.beat(now: 0.5)
    #expect(gate.sample(10, now: 1) == 0.25)
    #expect(gate.sample(1, now: 2) == nil)
    #expect(!gate.enabled)
    gate.setEnabled(true, now: 2)
    #expect(!gate.enabled)
    gate.setEnabled(false, now: 2); gate.setEnabled(true, now: 2)
    #expect(gate.sample(.nan, now: 2.1) == nil)
}
