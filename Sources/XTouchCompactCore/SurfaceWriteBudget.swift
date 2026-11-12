import Foundation

/// Host-only mutation budget for the shared surface tools. Legacy tools keep their policy.
public struct SurfaceWriteBudget: Sendable {
    public static let writesPerSecond = 60
    private var windowStarted: Double?
    private var lastTime: Double?
    private var count = 0
    public init() {}
    public mutating func consume(at time: Double) -> Bool {
        guard time.isFinite, lastTime.map({ time >= $0 }) ?? true else { return false }
        if windowStarted.map({ time - $0 >= 1 }) ?? true {
            windowStarted = time
            count = 0
        }
        lastTime = time
        guard count < Self.writesPerSecond else { return false }
        count += 1
        return true
    }
}
