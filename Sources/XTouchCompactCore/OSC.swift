import Foundation
import struct ParameterOutputPlugin.MotionSafetyGate
import enum ParameterOutputPlugin.OSCCodec
import SurfacePluginContracts

public enum OSCError: Error { case invalidAddress, nonFinite, invalidLimits }
/// The legacy single-float API is only a transport-shape adapter.
public enum OSCCodec {
    public static func encode(address: String, value: Float) throws -> Data {
        guard address.hasPrefix("/"), !address.contains("\0"), address.utf8.count <= 512,
              address.utf8.allSatisfy({ $0 < 128 }) else { throw OSCError.invalidAddress }
        guard value.isFinite else { throw OSCError.nonFinite }
        do { return try ParameterOutputPlugin.OSCCodec.encode(.message(.init(address, [.float(value)]))) }
        catch { throw OSCError.invalidAddress }
    }
}

/// Source compatibility for the former scalar API; all safety decisions are shared.
/// Actual values and heartbeats must come from a trusted host telemetry source.
public struct MotionSafetyGate: Sendable {
    private var shared: ParameterOutputPlugin.MotionSafetyGate
    private var requested = false
    private static let valueID: ParameterID = "output.value"
    public var enabled: Bool {
        requested && shared.status == .ready
    }

    public var output: Double {
        shared.outputs[Self.valueID] ?? min(max(0, minimum), maximum)
    }

    public let minimum: Double
    public let maximum: Double
    public let maximumSpeed: Double
    public let timeout: TimeInterval
    public init(minimum: Double = 0, maximum: Double = 1, maximumSpeed: Double = 0.25, timeout: TimeInterval = 0.3) throws {
        self.minimum = minimum; self.maximum = maximum; self.maximumSpeed = maximumSpeed; self.timeout = timeout
        do {
            shared = try .init(limits: [.init(id: Self.valueID, minimum: minimum, maximum: maximum,
                                              maximumChange: maximum - minimum, maximumVelocity: maximumSpeed)],
                               heartbeatTimeout: timeout, precision: .float32)
        } catch { throw OSCError.invalidLimits }
    }

    public mutating func setConnected(_ connected: Bool, now: TimeInterval) {
        shared.setConnected(connected, at: now)
    }

    public mutating func receiveActual(_ value: Double, now: TimeInterval) {
        shared.receiveActual([.init(id: Self.valueID, value: value, receivedAt: now)])
    }

    public mutating func beat(now: TimeInterval) {
        shared.receiveHeartbeat(at: now)
    }

    public mutating func setEnabled(_ enabled: Bool, now: TimeInterval) {
        if !enabled {
            requested = false; _ = shared.evaluate(targets: [:], enabled: false, at: now); return
        }
        requested = true
    }

    public mutating func sample(_ desired: Double, now: TimeInterval) -> Double? {
        let decision = shared.evaluate(targets: [Self.valueID: desired], enabled: requested, at: now)
        guard let command = decision.command, command.enabled else { requested = false; return nil }
        return command.values[Self.valueID]
    }
}
