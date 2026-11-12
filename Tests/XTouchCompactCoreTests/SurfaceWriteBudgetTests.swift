import Testing
@testable import XTouchCompactCore

@Test func sharedToolWriteBudgetIsBoundedAndRejectsClockRegression() {
    var budget = SurfaceWriteBudget()
    var sequence: [(Double, Bool)] = Array(repeating: (100, true), count: 60)
    sequence += [(100, false), (99, false), (.nan, false), (.infinity, false), (100.99, false), (101, true), (100.5, false)]
    for (time, expected) in sequence {
        let accepted = budget.consume(at: time)
        #expect(accepted == expected)
    }
}
