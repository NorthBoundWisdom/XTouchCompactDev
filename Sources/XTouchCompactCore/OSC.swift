import Foundation

public enum OSCError: Error { case invalidAddress, nonFinite, invalidLimits }
public enum OSCCodec {
    public static func encode(address: String, value: Float) throws -> Data {
        guard address.hasPrefix("/"), !address.contains("\0"), address.utf8.count <= 512 else { throw OSCError.invalidAddress }
        guard value.isFinite else { throw OSCError.nonFinite }
        func string(_ value: String) -> Data {
            var bytes = Array(value.utf8) + [0]
            while bytes.count % 4 != 0 {
                bytes.append(0)
            }
            return Data(bytes)
        }
        var bits = value.bitPattern.bigEndian
        return string(address) + string(",f") + withUnsafeBytes(of: &bits) { Data($0) }
    }
}

public struct MotionSafetyGate: Sendable {
    public private(set) var enabled = false
    public private(set) var output: Double
    public let minimum: Double
    public let maximum: Double
    public let maximumSpeed: Double
    public let timeout: TimeInterval
    private var sawDisabled = false
    private var heartbeat: TimeInterval?
    private var lastTime: TimeInterval?
    public init(minimum: Double = 0, maximum: Double = 1, maximumSpeed: Double = 0.25, timeout: TimeInterval = 1) throws {
        guard minimum.isFinite, maximum.isFinite, minimum < maximum, maximumSpeed.isFinite, maximumSpeed > 0,
              timeout.isFinite, timeout > 0 else { throw OSCError.invalidLimits }
        self.minimum = minimum; self.maximum = maximum; self.maximumSpeed = maximumSpeed; self.timeout = timeout
        output = min(max(0, minimum), maximum)
    }

    public mutating func setEnabled(_ enabled: Bool, now: TimeInterval) {
        guard now.isFinite else { trip(); return }
        if !enabled {
            self.enabled = false; sawDisabled = true; lastTime = nil; return
        }
        guard sawDisabled else { return }
        self.enabled = true; sawDisabled = false; heartbeat = now; lastTime = now
    }

    public mutating func beat(now: TimeInterval) {
        guard now.isFinite, heartbeat.map({ now >= $0 && now - $0 <= timeout }) ?? false else { trip(); return }
        heartbeat = now
    }

    public mutating func sample(_ desired: Double, now: TimeInterval) -> Double? {
        guard enabled else { return nil }
        guard desired.isFinite, now.isFinite, let heartbeat, let lastTime,
              now >= lastTime, now >= heartbeat, now - heartbeat <= timeout else { trip(); return nil }
        let distance = maximumSpeed * (now - lastTime)
        let clamped = min(max(desired, minimum), maximum)
        output = min(max(clamped, output - distance), output + distance)
        self.lastTime = now
        return output
    }

    private mutating func trip() {
        enabled = false; sawDisabled = false; heartbeat = nil; lastTime = nil
    }
}
