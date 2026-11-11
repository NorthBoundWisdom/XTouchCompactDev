import Foundation
import Testing
@testable import XTouchCompactCore

private func reviewedPrerequisites() -> NonMotorTestPrerequisites {
    .init(standardModeConfirmed: true, stage1Reviewed: true, stage1Evidence: "synthetic Stage 1 fixture",
          firmware: "fixture 1.14", receiveChannel: 5, receiveChannelEvidence: "independent fixture settings ch6")
}

@Test func typedNonMotorCommandsCoverBothLEDVariantsAndAllRingShapes() throws {
    for index in 1 ... 39 {
        for variant in [ButtonLightProtocol.manual, .observed114] {
            for light in ButtonLight.allCases {
                let message = try NonMotorTestCommand.button(index, light, variant).message(receiveChannel: 5)
                #expect(message == .noteOn(channel: 5, number: UInt8(index - 1), velocity: variant.velocity(for: light)))
                #expect(NonMotorTestCommand.isNonMotorFeedback(message, receiveChannel: 5))
            }
        }
    }
    let displays: [RingDisplay] = [.off, .allOn, .allBlinking] + (1 ... 13).map { .position($0) } + (1 ... 13).map { .blinkingPosition($0) }
    for index in 1 ... 16 {
        for display in displays {
            let message = try NonMotorTestCommand.ring(index, display).message(receiveChannel: 5)
            #expect(NonMotorTestCommand.isNonMotorFeedback(message, receiveChannel: 5))
            if case let .controlChange(c, number, _) = message {
                #expect(c == 5 && number == UInt8(25 + index))
            }
        }
        for style in RingStyle.allCases {
            #expect(try NonMotorTestCommand.style(index, style).message(receiveChannel: 5) == .controlChange(channel: 5, number: UInt8(9 + index), value: style.rawValue))
        }
    }
    #expect(try NonMotorTestCommand.ring(3, .position(13)).message(receiveChannel: 5) == .controlChange(channel: 5, number: 28, value: 13))
    #expect(try NonMotorTestCommand.layer(.b).message(receiveChannel: 5) == .programChange(channel: 5, number: 1))
    #expect(try NonMotorTestCommand.layer(.a).message(receiveChannel: 5) == .programChange(channel: 5, number: 0))
}

@Test func nonMotorWhitelistRejectsEveryMotorAndModeValue() {
    for number: UInt8 in Array(1 ... 9) + [127] {
        for value: UInt8 in 0 ... 127 {
            #expect(!NonMotorTestCommand.isNonMotorFeedback(.controlChange(channel: 5, number: number, value: value), receiveChannel: 5))
        }
    }
    for message: MIDIMessage in [.pitchBend(channel: 5, value: 0), .noteOff(channel: 5, number: 0, velocity: 0),
                                 .noteOn(channel: 5, number: 39, velocity: 1), .programChange(channel: 5, number: 2),
                                 .controlChange(channel: 4, number: 26, value: 13), .controlChange(channel: 5, number: 26, value: 29),
                                 .controlChange(channel: 5, number: 10, value: 5)]
    {
        #expect(!NonMotorTestCommand.isNonMotorFeedback(message, receiveChannel: 5))
    }
}

@Test func nonMotorPermissionRequiresExplicitFactsRecordingAndRoute() throws {
    var gate = NonMotorTestGate()
    let context = NonMotorTransportContext(inputID: -10, outputID: -20, recording: true)
    let missing: [(inout NonMotorTestPrerequisites) -> Void] = [
        { $0.standardModeConfirmed = false }, { $0.stage1Reviewed = false },
        { $0.stage1Evidence = "  " }, { $0.firmware = "" }, { $0.receiveChannel = nil },
        { $0.receiveChannel = 16 }, { $0.receiveChannelEvidence = "" },
    ]
    for mutate in missing {
        try gate.arm(reviewedPrerequisites(), context: context, id: "old")
        var facts = reviewedPrerequisites(); mutate(&facts)
        #expect(throws: NonMotorTestError.self) { try gate.arm(facts, context: context, id: "new") }
        #expect(gate.approval == nil)
    }
    #expect(throws: NonMotorTestError.self) { try gate.arm(reviewedPrerequisites(), context: .init(inputID: -10, outputID: -20, recording: false), id: "none") }
    #expect(throws: NonMotorTestError.self) { try gate.arm(reviewedPrerequisites(), context: .init(inputID: nil, outputID: -20, recording: true), id: "none") }
}

@Test func exactNonMotorGrantCannotBeReplayedOnNewEpochOrModifiedIntoMotorBatch() throws {
    var gate = NonMotorTestGate()
    let context = NonMotorTransportContext(inputID: -10, outputID: -20, recording: true, generation: 7)
    try gate.arm(reviewedPrerequisites(), context: context, id: "one")
    let request = try gate.authorize(.button(1, .blink, .observed114), context: context)
    try gate.validate(request, messages: [request.message], context: context)
    #expect(throws: NonMotorTestError.self) { try gate.validate(request, messages: [request.message, .controlChange(channel: 5, number: 1, value: 20)], context: context) }
    #expect(throws: NonMotorTestError.self) { try gate.validate(request, messages: [.controlChange(channel: 5, number: 1, value: 20)], context: context) }
    for changed in [NonMotorTransportContext(inputID: -10, outputID: -20, recording: true, generation: 8),
                    .init(inputID: -10, outputID: -21, recording: true, generation: 7),
                    .init(inputID: -10, outputID: -20, recording: false, generation: 7)]
    {
        #expect(throws: NonMotorTestError.self) { try gate.validate(request, messages: [request.message], context: changed) }
    }
    gate.disarm()
    try gate.arm(reviewedPrerequisites(), context: context, id: "two")
    #expect(throws: NonMotorTestError.self) { try gate.validate(request, messages: [request.message], context: context) }
    #expect(throws: CompactError.self) { try gate.authorize(.button(40, .on, .manual), context: context) }
    #expect(throws: CompactError.self) { try gate.authorize(.ring(1, .position(14)), context: context) }
}

@Test func nonMotorInvalidationDoesNotFabricateMotorObservationOrForgetMotorCommand() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.connect()
    session.observeInputs([.controlChange(channel: 0, number: 1, value: 20)])
    _ = try session.setFader(1, value: 80)
    _ = try session.setEncoder(1, value: 64)
    session.invalidateNonMotorFeedback()
    #expect(try session.setFader(1, value: 80).isEmpty)
    #expect(try session.setEncoder(1, value: 64).count == 1)
    #expect(session.state.observedFader(1) == 20)
}
