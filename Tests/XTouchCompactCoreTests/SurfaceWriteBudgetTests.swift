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

@Test func independentDisplayBudgetsDoNotConsumeOwnerOrOtherWriters() {
    var budget = SurfaceWriteBudgets(input: 1, feedback: 2, renew: 1, admin: 1, independentFeedbackWriters: ["display.one", "display.two"])
    let result1 = budget.consume(.feedback, at: 10, writerID: "display.one")
    #expect(result1)
    let result2 = budget.consume(.feedback, at: 10, writerID: "display.one")
    #expect(result2)
    let result3 = !budget.consume(.feedback, at: 10, writerID: "display.one")
    #expect(result3)
    let result4 = budget.consume(.feedback, at: 10, writerID: "display.two")
    #expect(result4)
    let result5 = budget.consume(.feedback, at: 10)
    #expect(result5)
    let result6 = budget.consume(.feedback, at: 10)
    #expect(result6)
    let result7 = !budget.consume(.feedback, at: 10)
    #expect(result7)
    let result8 = !budget.consume(.feedback, at: 9, writerID: "display.two")
    #expect(result8)
    let result9 = !budget.consume(.feedback, at: .nan, writerID: "display.two")
    #expect(result9)
    let result10 = budget.consume(.feedback, at: 11, writerID: "display.one")
    #expect(result10)
}

@Test func extendedDefaultDisplaysKeepSixtyWhileOwnerOperatorShareAggregate() {
    var budget = SurfaceWriteBudgets(aggregateLimit: 1, independentFeedbackWriters: ["display.one", "display.two"])
    for _ in 0 ..< 60 {
        let result11 = budget.consume(.feedback, at: 10, writerID: "display.one")
        #expect(result11)
    }
    let result12 = !budget.consume(.feedback, at: 10, writerID: "display.one")
    #expect(result12)
    let result13 = budget.consume(.feedback, at: 10, writerID: "display.two")
    #expect(result13)
    let result14 = budget.consume(.input, at: 10, writerID: "owner")
    #expect(result14)
    let result15 = !budget.consume(.input, at: 10, writerID: "operator")
    #expect(result15)
}
