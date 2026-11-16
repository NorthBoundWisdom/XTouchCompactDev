import Foundation

/// Optional per-category host budgets for surface_control only. Legacy tools and the default
/// aggregate budget keep their existing policy. A failed consumption does not commit counters.
public struct SurfaceWriteBudgets: Sendable {
    public enum Category: String, CaseIterable, Sendable { case input, feedback, renew, admin }
    private var aggregate: SurfaceWriteBudget?
    private var categories: [Category: SurfaceWriteBudget]
    private var lastTime: Double?
    private var feedbackByWriter: [String: SurfaceWriteBudget]

    public init(aggregateLimit: Int = SurfaceWriteBudget.writesPerSecond, independentFeedbackWriters: Set<String> = []) {
        aggregate = .init(limit: aggregateLimit)
        categories = [:]
        feedbackByWriter = Dictionary(uniqueKeysWithValues: independentFeedbackWriters.map { ($0, .init()) })
    }

    public init(input: Int, feedback: Int, renew: Int, admin: Int, independentFeedbackWriters: Set<String> = []) {
        aggregate = nil
        categories = [.input: .init(limit: input), .feedback: .init(limit: feedback),
                      .renew: .init(limit: renew), .admin: .init(limit: admin)]
        feedbackByWriter = Dictionary(uniqueKeysWithValues: independentFeedbackWriters.map { ($0, .init(limit: feedback)) })
    }

    public mutating func consume(_ category: Category, at time: Double, writerID: String? = nil) -> Bool {
        guard time.isFinite, lastTime.map({ time >= $0 }) ?? true else { return false }
        if category == .feedback, let writerID, var budget = feedbackByWriter[writerID] {
            guard budget.consume(at: time) else { return false }
            feedbackByWriter[writerID] = budget
            lastTime = time
            return true
        }
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
