import Foundation

/// Host-only mutation budget for the shared surface tools. Legacy tools keep their policy.
public struct SurfaceWriteBudget: Sendable {
    public static let writesPerSecond = 60
    private let limit: Int
    private var windowStarted: Double?
    private var lastTime: Double?
    private var count = 0
    public init(limit: Int = Self.writesPerSecond) {
        precondition((1 ... 10000).contains(limit))
        self.limit = limit
    }

    public mutating func consume(at time: Double) -> Bool {
        guard time.isFinite, lastTime.map({ time >= $0 }) ?? true else { return false }
        if windowStarted.map({ time - $0 >= 1 }) ?? true {
            windowStarted = time
            count = 0
        }
        lastTime = time
        guard count < limit else { return false }
        count += 1
        return true
    }
}
