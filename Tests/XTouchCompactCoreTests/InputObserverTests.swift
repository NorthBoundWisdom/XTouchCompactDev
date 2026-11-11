import Foundation
import Testing
@testable import XTouchCompactCore

@Test func observerRetainsPhysicalStateAfterHistoryExpiresAndKeepsLayersSeparate() throws {
    let map = try FactoryStandardMap(transmitChannel: 3, globalReceiveChannel: 11)
    let time = Date(timeIntervalSince1970: 123)
    var observer = CompactInputObserver()
    observer.receive(.controlChange(channel: 3, number: 101, value: 127), map: map, at: time)
    observer.receive(.controlChange(channel: 3, number: 1, value: 73), map: map, at: time)
    observer.receive(.controlChange(channel: 3, number: 10, value: 20), map: map, at: time)
    for value in 0 ..< 128 {
        observer.receive(.controlChange(channel: 3, number: 37, value: UInt8(value)), map: map, at: time)
    }
    #expect(observer.messageCount == 131)
    #expect(observer.recent.count == 12)
    #expect(observer.recent.first?.id == 131)
    #expect(observer.recent.last?.id == 120)
    #expect(observer.recent.first?.channel == 3) // Core channels stay zero-based.
    #expect(observer.recent.first?.timestamp == time)
    #expect(observer.faderPositions[1] == 73)
    #expect(observer.faderTouches[1] == true)
    #expect(observer.encoderValues[.a]?[1] == 20)
    #expect(observer.encoderValues[.b]?[1] == 127)
    #expect(observer.inputLayer == .b)
    #expect(observer.seenControls == [.fader(1), .faderTouch(1), .encoder(1)])
    // Release on another layer clears the physical hold without changing its last position.
    observer.receive(.controlChange(channel: 3, number: 111, value: 0), map: map, at: time)
    #expect(observer.faderTouches[1] == false)
    #expect(observer.faderPositions[1] == 73)
}

@Test func observerPreservesUnknownAndWrongChannelMessagesWithoutInventingState() throws {
    let map = try FactoryStandardMap(transmitChannel: 0, globalReceiveChannel: 11)
    let time = Date(timeIntervalSince1970: 123)
    var observer = CompactInputObserver()
    let wrongChannel = MIDIMessage.controlChange(channel: 4, number: 101, value: 127)
    observer.receive(wrongChannel, map: map, at: time)
    #expect(observer.recent.first?.message == wrongChannel)
    #expect(observer.recent.first?.channel == 4)
    #expect(observer.recent.first?.matchesConfiguredChannel == false)
    #expect(observer.recent.first?.input == nil)
    #expect(observer.faderTouches.isEmpty)
    observer.receive(.pitchBend(channel: 0, value: 8192), map: map, at: time)
    observer.receive(.programChange(channel: 0, number: 1), map: map, at: time)
    #expect(observer.messageCount == 3)
    #expect(observer.inputLayer == nil) // An assertion or unrelated message proves no layer.
    #expect(observer.seenControls.isEmpty)
    #expect(observer.faderPositions.isEmpty)
    #expect(observer.encoderValues.isEmpty)
    #expect(map.globalReceiveChannel == 11)
}

@Test func observerRetainsNotePressAndReleaseSemanticsWithoutLEDClaims() throws {
    let map = try FactoryStandardMap()
    let time = Date(timeIntervalSince1970: 123)
    var observer = CompactInputObserver()
    observer.receive(.noteOn(channel: 0, number: 0, velocity: 127), map: map, at: time)
    observer.receive(.noteOn(channel: 0, number: 16, velocity: 127), map: map, at: time)
    #expect(observer.encoderPushes[1] == true)
    #expect(observer.buttonPresses[1] == true)
    observer.receive(.noteOn(channel: 0, number: 0, velocity: 0), map: map, at: time)
    observer.receive(.noteOff(channel: 0, number: 16, velocity: 0), map: map, at: time)
    #expect(observer.encoderPushes[1] == false)
    #expect(observer.buttonPresses[1] == false)
    #expect(observer.seenControls == [.encoderPush(1), .button(1)])
    #expect(observer.faderTouches[1] == nil)
    #expect(observer.faderPositions[1] == nil)
}
