import Foundation

/// Optional per-category host budgets for surface_control only. Legacy tools and the default
/// aggregate budget keep their existing policy. A failed consumption does not commit counters.
public struct SurfaceWriteBudgets: Sendable {
    public enum Category: String, CaseIterable, Sendable { case input, feedback, renew, admin }
    private var aggregate: SurfaceWriteBudget?
    private var categories: [Category: SurfaceWriteBudget]
    private var lastTime: Double?

    public init(aggregateLimit: Int = SurfaceWriteBudget.writesPerSecond) {
        aggregate = .init(limit: aggregateLimit)
        categories = [:]
    }

    public init(input: Int, feedback: Int, renew: Int, admin: Int) {
        aggregate = nil
        categories = [.input: .init(limit: input), .feedback: .init(limit: feedback),
                      .renew: .init(limit: renew), .admin: .init(limit: admin)]
    }

    public mutating func consume(_ category: Category, at time: Double) -> Bool {
        guard time.isFinite, lastTime.map({ time >= $0 }) ?? true else { return false }
        if var budget = aggregate {
            guard budget.consume(at: time) else { return false }
            aggregate = budget
        } else {
            guard var budget = categories[category], budget.consume(at: time) else { return false }
            categories[category] = budget
        }
        lastTime = time
        return true
    }
}
