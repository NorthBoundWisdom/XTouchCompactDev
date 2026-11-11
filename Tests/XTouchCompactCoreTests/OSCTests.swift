import Foundation
import Testing
@testable import XTouchCompactCore

@Test func oscPacketAndSafetyGate() throws {
    #expect(try OSCCodec.encode(address: "/x", value: 1) == Data([47, 120, 0, 0, 44, 102, 0, 0, 63, 128, 0, 0]))
    #expect(throws: OSCError.self) { _ = try OSCCodec.encode(address: "x", value: 1) }
    #expect(throws: OSCError.self) { _ = try OSCCodec.encode(address: "/x", value: .nan) }
    #expect(throws: OSCError.self) { _ = try OSCCodec.encode(address: "/非ASCII", value: 1) }
    var gate = try MotionSafetyGate()
    gate.setConnected(true, now: 0)
    gate.beat(now: 0); gate.receiveActual(0, now: 0)
    gate.setEnabled(true, now: 0)
    #expect(gate.sample(1, now: 0) == nil) // Explicit off/on remains required.
    gate.setEnabled(false, now: 0); gate.setEnabled(true, now: 0)
    #expect(gate.sample(10, now: 0) == 0) // First command is the measured baseline.
    gate.beat(now: 0.25); gate.receiveActual(0, now: 0.25)
    #expect(gate.sample(10, now: 0.25) == 0.0625)
    gate.beat(now: 0.5); gate.receiveActual(0.0625, now: 0.5)
    #expect(gate.sample(10, now: 0.5) == 0.125)
    #expect(gate.sample(1, now: 1) == nil)
    #expect(!gate.enabled)
    gate.beat(now: 1); gate.receiveActual(0.125, now: 1)
    gate.setEnabled(true, now: 1)
    #expect(gate.sample(1, now: 1) == nil) // A late heartbeat cannot clear the trip.
    gate.setConnected(false, now: 1); gate.setConnected(true, now: 1)
    gate.beat(now: 1); gate.receiveActual(0.125, now: 1)
    gate.setEnabled(false, now: 1); gate.setEnabled(true, now: 1)
    #expect(gate.sample(.nan, now: 1) == nil)
}

@Test func outputCannotUseRequestsAsActualStateOrItsOwnSchedulerAsHeartbeat() throws {
    var gate = try MotionSafetyGate()
    gate.setConnected(true, now: 0)
    gate.setEnabled(false, now: 0); gate.setEnabled(true, now: 0)
    #expect(gate.sample(1, now: 0) == nil)
    gate.beat(now: 0)
    gate.setEnabled(false, now: 0); gate.setEnabled(true, now: 0)
    #expect(gate.sample(1, now: 0) == nil)
    #expect(!gate.enabled)
    #expect(throws: OSCError.self) { _ = try MotionSafetyGate(timeout: 1) }
}

@Test func scalarAdapterCannotSeedFloatOutputBeyondItsSoftLimit() throws {
    var gate = try MotionSafetyGate(minimum: 0, maximum: 0.1)
    gate.setConnected(true, now: 0)
    gate.beat(now: 0); gate.receiveActual(0.1, now: 0)
    gate.setEnabled(false, now: 0); gate.setEnabled(true, now: 0)
    #expect(gate.sample(0.1, now: 0) == nil)
    #expect(!gate.enabled)
    gate.receiveActual(0.0625, now: 0)
    gate.setEnabled(true, now: 0)
    #expect(gate.sample(0.0625, now: 0) == nil)
    gate.setEnabled(false, now: 0); gate.setEnabled(true, now: 0)
    #expect(gate.sample(0.0625, now: 0) == 0.0625)
}
