import Foundation

public enum NonMotorReportedResponse: String, CaseIterable, Sendable { case matches, differs, noResponse }

/// Operator attestations are not discovered device facts and never rewrite a profile.
public struct NonMotorTestPrerequisites: Equatable, Sendable {
    public var standardModeConfirmed: Bool
    public var stage1Reviewed: Bool
    public var stage1Evidence: String
    public var firmware: String
    public var receiveChannel: UInt8?
    public var receiveChannelEvidence: String

    public init(standardModeConfirmed: Bool = false, stage1Reviewed: Bool = false, stage1Evidence: String = "", firmware: String = "", receiveChannel: UInt8? = nil, receiveChannelEvidence: String = "") {
        self.standardModeConfirmed = standardModeConfirmed; self.stage1Reviewed = stage1Reviewed
        self.stage1Evidence = stage1Evidence; self.firmware = firmware
        self.receiveChannel = receiveChannel; self.receiveChannelEvidence = receiveChannelEvidence
    }

    public var isComplete: Bool {
        standardModeConfirmed && stage1Reviewed && receiveChannel.map { $0 < 16 } == true &&
            [stage1Evidence, firmware, receiveChannelEvidence].allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

public struct NonMotorTransportContext: Equatable, Sendable {
    public let inputID: Int32?
    public let outputID: Int32?
    public let recording: Bool
    public let generation: UInt64
    public init(inputID: Int32?, outputID: Int32?, recording: Bool, generation: UInt64 = 0) {
        self.inputID = inputID; self.outputID = outputID; self.recording = recording; self.generation = generation
    }
}

/// Factory RX feedback only. In particular CC 28 is a ring address, even though
/// Layer B transmits F1 position on CC 28. No mode switch or motor CC is expressible;
/// the layer assertion can still cycle all nine firmware motors.
public enum NonMotorTestCommand: Equatable, Sendable {
    case button(Int, ButtonLight, ButtonLightProtocol)
    case ring(Int, RingDisplay)
    case style(Int, RingStyle)
    case layer(CompactLayer)

    public var control: CompactControl? {
        switch self {
        case let .button(index, _, _): .button(index)
        case let .ring(index, _), let .style(index, _): .encoder(index)
        case .layer: nil
        }
    }

    public var kind: String {
        switch self { case .button: "button"; case .ring: "ring-display"; case .style: "ring-style"; case .layer: "layer-assertion" }
    }

    public func message(receiveChannel: UInt8) throws -> MIDIMessage {
        let map = try FactoryStandardMap(globalReceiveChannel: receiveChannel)
        switch self {
        case let .button(index, light, variant): return try map.buttonLight(button: index, light: light, style: variant)
        case let .ring(index, display): return try map.encoderRingValue(encoder: index, display: display)
        case let .style(index, style): return try map.encoderRingStyle(encoder: index, style: style)
        case let .layer(layer): return map.selectLayer(layer)
        }
    }

    public static func isNonMotorFeedback(_ message: MIDIMessage, receiveChannel: UInt8) -> Bool {
        guard receiveChannel < 16 else { return false }
        switch message {
        case let .controlChange(c, n, v):
            return c == receiveChannel && ((10 ... 25).contains(n) && v <= 4 || (26 ... 41).contains(n) && v <= 28)
        case let .noteOn(c, n, v): return c == receiveChannel && n <= 38 && v <= 3
        case let .programChange(c, n): return c == receiveChannel && n <= 1
        case .noteOff, .pitchBend: return false
        }
    }
}

public enum NonMotorTestError: Error { case prerequisitesMissing, recordingRequired, connectionMissing, permissionRevoked, connectionChanged, invalidTransmission, observationUnavailable, previewRequired }

public struct NonMotorTestApproval: Equatable, Sendable {
    public let id: String
    public let prerequisites: NonMotorTestPrerequisites
    public let inputID: Int32
    public let outputID: Int32
    public let generation: UInt64
}

public struct AuthorizedNonMotorTest: Equatable, Sendable {
    public let approval: NonMotorTestApproval
    public let command: NonMotorTestCommand
    public let message: MIDIMessage
}

/// Session-only permission, pinned to the reviewed route and explicit RX choice.
/// Every transport attempt revalidates both identity and the exact single command.
public struct NonMotorTestGate: Equatable, Sendable {
    public private(set) var approval: NonMotorTestApproval?
    public init() {}

    public mutating func arm(_ prerequisites: NonMotorTestPrerequisites, context: NonMotorTransportContext, id: String) throws {
        approval = nil
        guard prerequisites.isComplete else { throw NonMotorTestError.prerequisitesMissing }
        guard context.recording else { throw NonMotorTestError.recordingRequired }
        guard let input = context.inputID, let output = context.outputID, input != 0, output != 0 else { throw NonMotorTestError.connectionMissing }
        approval = NonMotorTestApproval(id: id, prerequisites: prerequisites, inputID: input, outputID: output, generation: context.generation)
    }

    public mutating func disarm() {
        approval = nil
    }

    public func authorize(_ command: NonMotorTestCommand, context: NonMotorTransportContext) throws -> AuthorizedNonMotorTest {
        guard let approval else { throw NonMotorTestError.permissionRevoked }
        guard let channel = approval.prerequisites.receiveChannel else { throw NonMotorTestError.prerequisitesMissing }
        let result = try AuthorizedNonMotorTest(approval: approval, command: command, message: command.message(receiveChannel: channel))
        try validate(result, messages: [result.message], context: context)
        return result
    }

    public func validate(_ request: AuthorizedNonMotorTest, messages: [MIDIMessage], context: NonMotorTransportContext) throws {
        guard let approval, request.approval == approval else { throw NonMotorTestError.permissionRevoked }
        guard context.recording else { throw NonMotorTestError.recordingRequired }
        guard context.inputID == approval.inputID, context.outputID == approval.outputID, context.generation == approval.generation else { throw NonMotorTestError.connectionChanged }
        guard let channel = approval.prerequisites.receiveChannel,
              messages == [request.message],
              try request.message == (request.command.message(receiveChannel: channel)),
              NonMotorTestCommand.isNonMotorFeedback(request.message, receiveChannel: channel) else { throw NonMotorTestError.invalidTransmission }
    }
}
