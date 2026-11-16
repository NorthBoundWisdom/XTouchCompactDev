import Testing
@testable import XTouchCompactCore

@Test func accessibleRawControlAdjustmentReachesEveryValueAndClampsEndpoints() {
    #expect(RawControlAdjustment.next(0, increment: false) == 0)
    #expect(RawControlAdjustment.next(127, increment: true) == 127)
    var value: UInt8 = 0
    for expected in 1 ... 127 {
        value = RawControlAdjustment.next(value, increment: true)
        #expect(Int(value) == expected)
    }
    for expected in (0 ..< 127).reversed() {
        value = RawControlAdjustment.next(value, increment: false)
        #expect(Int(value) == expected)
    }
}
