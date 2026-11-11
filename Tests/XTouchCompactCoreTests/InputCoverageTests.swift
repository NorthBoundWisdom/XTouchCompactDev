import Foundation
import Testing
@testable import XTouchCompactCore

@Test func inputGroupsEnumerateEveryPhysicalInputExactlyOnce() {
    let all = CompactInputGroup.allCases.flatMap(\.controls)
    #expect(all.count == 89)
    #expect(Set(all).count == all.count)
    #expect(CompactInputGroup.allCases.map(\.controls.count) == [9, 9, 16, 16, 39])
}

@Test func inputReviewsRetainRangesAddressesAndLayerIsolationBeyondHistory() throws {
    var observer = CompactInputObserver()
    let map = try FactoryStandardMap(transmitChannel: 4, globalReceiveChannel: 11)
    let time = Date(timeIntervalSince1970: 123)
    for raw in [0, 20, 127] {
        observer.receive(.controlChange(channel: 4, number: 1, value: UInt8(raw)), map: map, at: time)
    }
    for raw in 0 ..< 128 {
        observer.receive(.controlChange(channel: 4, number: 37, value: UInt8(raw)), map: map, at: time)
    }
    let a = try #require(observer.reviews[.a]?[.fader(1)])
    #expect(a.eventCount == 3)
    #expect(a.minimum == 0 && a.maximum == 127)
    #expect(a.addresses.map(\.description) == ["CC ch5 #1"])
    #expect(observer.reviews[.b]?[.encoder(1)]?.minimum == 0)
    #expect(observer.reviews[.b]?[.encoder(1)]?.maximum == 127)
    #expect(observer.reviews[.a]?[.encoder(1)] == nil)
    #expect(observer.recent.count == 12)
}

@Test func crossLayerReleasePairsWithItsOriginAndDoesNotInventDestinationPress() throws {
    var observer = CompactInputObserver()
    let map = try FactoryStandardMap()
    let time = Date(timeIntervalSince1970: 123)
    observer.receive(.controlChange(channel: 0, number: 101, value: 127), map: map, at: time)
    observer.receive(.controlChange(channel: 0, number: 111, value: 0), map: map, at: time)
    #expect(observer.reviews[.a]?[.faderTouch(1)]?.pairCount == 1)
    #expect(observer.reviews[.a]?[.faderTouch(1)]?.isDown == false)
    #expect(observer.reviews[.b]?[.faderTouch(1)]?.pressCount == 0)
    #expect(observer.reviews[.b]?[.faderTouch(1)]?.pairCount == 0)
    #expect(observer.reviews[.b]?[.faderTouch(1)]?.unmatchedReleaseCount == 0)
    #expect(observer.crossLayerReleases[CrossLayerRelease(control: .faderTouch(1), pressedLayer: .a, releasedLayer: .b)] == 1)
    #expect(observer.faderTouches[1] == false)
}

@Test func repeatedPressesAndUnmatchedReleasesRemainReviewable() throws {
    var observer = CompactInputObserver()
    let map = try FactoryStandardMap()
    let time = Date(timeIntervalSince1970: 123)
    for velocity: UInt8 in [0, 127, 127, 0] {
        observer.receive(.noteOn(channel: 0, number: 16, velocity: velocity), map: map, at: time)
    }
    let review = try #require(observer.reviews[.a]?[.button(1)])
    #expect(review.pressCount == 2 && review.releaseCount == 2)
    #expect(review.pairCount == 1)
    #expect(review.duplicatePressCount == 1)
    #expect(review.unmatchedReleaseCount == 1)
}

@Test func crossLayerEvidenceRetainsOriginalAddressReleaseAfterOtherLayerInput() throws {
    var observer = CompactInputObserver()
    let map = try FactoryStandardMap()
    let time = Date(timeIntervalSince1970: 123)
    observer.receive(.controlChange(channel: 0, number: 101, value: 127), map: map, at: time)
    observer.receive(.controlChange(channel: 0, number: 37, value: 42), map: map, at: time)
    observer.receive(.controlChange(channel: 0, number: 101, value: 0), map: map, at: time)
    let evidence = CrossLayerRelease(control: .faderTouch(1), pressedLayer: .a, releasedLayer: .a, interveningLayer: .b)
    #expect(observer.crossLayerReleases[evidence] == 1)
    #expect(observer.reviews[.a]?[.faderTouch(1)]?.pairCount == 1)
    #expect(observer.reviews[.b]?[.faderTouch(1)] == nil)
    #expect(observer.faderTouches[1] == false)
}

@Test func captureIntegrityDistinguishesLivePrefixesFromCompletedSessions() throws {
    let start = "{\"kind\":\"capture-start\",\"schemaVersion\":1}\n"
    let event = "{\"kind\":\"event\",\"sequence\":1}\n"
    let end = "{\"kind\":\"capture-end\",\"eventCount\":1}\n"
    let live = try CaptureIntegrityReview(data: Data((start + event).utf8))
    #expect(!live.isComplete && live.eventCount == 1)
    #expect(try CaptureIntegrityReview(data: Data((start + event + end).utf8)).isComplete)
    for bad in [start + event + event, start + end, start + event + end + event, start + event + "{", start + "\n"] {
        #expect(throws: (any Error).self) { try CaptureIntegrityReview(data: Data(bad.utf8)) }
    }
}
