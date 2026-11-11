#if os(macOS)
    import Foundation
    import XTouchCompactCore

    struct NonMotorTestAttempt: Equatable, Identifiable, Sendable {
        let id: String
        let timestamp: Date
        let request: AuthorizedNonMotorTest
        var delivery: MonitorEvent.Delivery = .suppressed
        var observation: NonMotorReportedResponse?
        var note: String?

        var audit: NonMotorTestAudit {
            NonMotorTestAudit(phase: observation == nil ? "attempt-summary" : "operator-observation", approval: request.approval,
                              attemptID: id, command: request.command, message: request.message, delivery: delivery,
                              observation: observation, note: note)
        }
    }

    struct NonMotorTestAudit: Equatable, Sendable {
        var phase: String
        let approval: NonMotorTestApproval
        var attemptID: String?
        var command: NonMotorTestCommand?
        var message: MIDIMessage?
        var delivery: MonitorEvent.Delivery?
        var observation: NonMotorReportedResponse?
        var note: String?

        var json: [String: Any] {
            let facts = approval.prerequisites
            var row: [String: Any] = [
                "phase": phase, "approvalID": approval.id, "inputID": approval.inputID, "outputID": approval.outputID,
                "connectionGeneration": approval.generation,
                "operatorStandardModeConfirmed": facts.standardModeConfirmed, "operatorStage1Reviewed": facts.stage1Reviewed,
                "operatorStage1Evidence": facts.stage1Evidence, "operatorFirmware": facts.firmware,
                "operatorConfirmedReceiveChannel": facts.receiveChannel.map { Int($0) + 1 } as Any? ?? NSNull(),
                "operatorReceiveChannelEvidence": facts.receiveChannelEvidence,
                "operatorReportedResponse": observation?.rawValue as Any? ?? NSNull(),
            ]
            row["attemptID"] = attemptID; row["commandKind"] = command?.kind
            row["targetControl"] = command?.control?.description
            row["rawMIDI1Bytes"] = message?.midi1Bytes
            row["delivery"] = delivery?.rawValue; row["operatorNote"] = note
            if case let .button(_, light, variant)? = command {
                row["buttonLight"] = String(describing: light); row["ledProtocol"] = variant.rawValue
            }
            if case let .layer(layer)? = command {
                row["requestedLayer"] = layer.rawValue
            }
            return row
        }

        func withDelivery(_ status: MonitorEvent.Delivery) -> NonMotorTestAudit {
            var result = self; result.phase = "transport-result"; result.delivery = status
            return result
        }
    }

    struct NonMotorTestState: Equatable, Sendable {
        private(set) var gate = NonMotorTestGate()
        private(set) var attempts: [NonMotorTestAttempt] = []
        private(set) var lastLockReason: String?
        private(set) var previewCommand: NonMotorTestCommand?
        private(set) var previewMessage: MIDIMessage?
        private(set) var previewChannel: UInt8?

        var approval: NonMotorTestApproval? {
            gate.approval
        }

        mutating func arm(_ prerequisites: NonMotorTestPrerequisites, context: NonMotorTransportContext, id: String) throws {
            try gate.arm(prerequisites, context: context, id: id)
            lastLockReason = nil
            clearPreview()
        }

        mutating func lock(_ reason: String) -> NonMotorTestAudit? {
            guard let approval else { return nil }
            gate.disarm(); lastLockReason = reason
            clearPreview()
            return NonMotorTestAudit(phase: "permission-revoked", approval: approval, note: reason)
        }

        mutating func preview(_ command: NonMotorTestCommand, channel: UInt8?) throws {
            clearPreview()
            guard let channel else { throw NonMotorTestError.previewRequired }
            let message = try command.message(receiveChannel: channel)
            guard NonMotorTestCommand.isNonMotorFeedback(message, receiveChannel: channel) else { throw NonMotorTestError.invalidTransmission }
            previewCommand = command; previewMessage = message; previewChannel = channel
        }

        func authorize(_ command: NonMotorTestCommand, context: NonMotorTransportContext) throws -> AuthorizedNonMotorTest {
            let request = try gate.authorize(command, context: context)
            guard previewCommand == command, previewMessage == request.message,
                  previewChannel == request.approval.prerequisites.receiveChannel else { throw NonMotorTestError.previewRequired }
            return request
        }

        private mutating func clearPreview() {
            previewCommand = nil; previewMessage = nil; previewChannel = nil
        }

        mutating func add(_ request: AuthorizedNonMotorTest, id: String, at time: Date) {
            attempts.insert(NonMotorTestAttempt(id: id, timestamp: time, request: request), at: 0)
            if attempts.count > 32 {
                attempts.removeLast()
            }
        }

        mutating func delivered(_ id: String, status: MonitorEvent.Delivery) {
            guard let index = attempts.firstIndex(where: { $0.id == id }) else { return }
            attempts[index].delivery = status
        }

        mutating func recordObservation(_ id: String, result: NonMotorReportedResponse, note: String,
                                        context: NonMotorTransportContext) throws -> NonMotorTestAudit
        {
            guard context.recording else { throw NonMotorTestError.recordingRequired }
            guard let first = attempts.first, first.id == id, first.delivery == .sent,
                  first.request.approval.inputID == context.inputID, first.request.approval.outputID == context.outputID,
                  first.request.approval.generation == context.generation
            else {
                throw NonMotorTestError.observationUnavailable
            }
            attempts[0].observation = result; attempts[0].note = note
            return attempts[0].audit
        }
    }
#endif
