#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    private func operatorFixture() -> NonMotorTestPrerequisites {
        .init(standardModeConfirmed: true, stage1Reviewed: true, stage1Evidence: "synthetic review fixture",
              firmware: "fixture 1.14", receiveChannel: 5, receiveChannelEvidence: "independent fixture setting ch6")
    }

    @MainActor private func recordingModel(_ root: URL) -> (ConsoleModel, FakeMIDIService) {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(); model.beginHardwareObservation(); model.startCapture(root.appendingPathComponent("capture.jsonl"))
        return (model, midi)
    }

    private func temporaryEvidenceRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test @MainActor func nonMotorPreviewAndMissingFactsNeverSendOrInventRX() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi)
        midi.connect(); model.beginHardwareObservation()
        model.previewNonMotorTest(.ring(3, .position(13)), receiveChannel: nil)
        #expect(model.panelSnapshot.nonMotorTests.preview == nil)
        model.previewNonMotorTest(.ring(3, .position(13)), receiveChannel: 5)
        #expect(model.panelSnapshot.nonMotorTests.preview?.message == .controlChange(channel: 5, number: 28, value: 13))
        model.armNonMotorTests(.init())
        model.performNonMotorTest(.layer(.b))
        #expect(model.nonMotorTests.approval == nil)
        #expect(model.listenOnly)
        #expect(midi.sendAttempts == 0)
        #expect(model.feedbackChannel == 1)
        #expect(model.captureMetadata().json["actualGlobalReceiveChannel"] is NSNull)
    }

    @Test @MainActor func exactNonMotorSendPreservesProfileAndBlocksNormalAndAgentFeedback() throws {
        let root = try temporaryEvidenceRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (model, midi) = recordingModel(root)
        let parameters = model.panelSnapshot.parameterValues
        model.armNonMotorTests(operatorFixture())
        #expect(!model.listenOnly)
        let command = NonMotorTestCommand.button(1, .blink, .observed114)
        model.previewNonMotorTest(command, receiveChannel: 0) // Approved RX, not this draft, is authoritative.
        model.performNonMotorTest(command)
        #expect(midi.sent == [.noteOn(channel: 5, number: 0, velocity: 3)])
        #expect(model.panelSnapshot.nonMotorTests.attempts.first?.reportedResponse == nil)
        #expect(model.panelSnapshot.nonMotorTests.attempts.first?.delivery == .sent)
        #expect(model.panelSnapshot.button(1)?.light == .off) // Sent blink is not an observed device light.
        #expect(model.panelSnapshot.parameterValues == parameters)
        #expect(model.feedbackChannel == 1 && !model.observedLEDVariant)
        #expect(model.session.state.map.globalReceiveChannel == 0)
        model.faderChanged(1, value: 99)
        model.agentPrimary(1, fromAgent: true)
        #expect(midi.sent.count == 1)
        #expect(!midi.sent.contains {
            if case .controlChange(_, 1 ... 9, _) = $0 {
                true
            } else {
                false
            }
        })
        let output = try #require(model.events.first { $0.nonMotorTest?.phase == "transport-result" && $0.delivery == .sent })
        #expect(output.control == .button(1))
        #expect(output.nonMotorTest?.json["operatorConfirmedReceiveChannel"] as? Int == 6)
        #expect(output.nonMotorTest?.json["operatorReportedResponse"] is NSNull)
        model.stopCapture()
        #expect(model.listenOnly && model.nonMotorTests.approval == nil)
    }

    @Test @MainActor func nonMotorCommandMustMatchFreshPreviewAndNeedsNewPermissionAfterRejection() throws {
        let root = try temporaryEvidenceRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (model, midi) = recordingModel(root)
        model.armNonMotorTests(operatorFixture())
        model.performNonMotorTest(.button(1, .on, .manual))
        #expect(midi.sendAttempts == 0 && model.listenOnly)
        model.armNonMotorTests(operatorFixture())
        model.previewNonMotorTest(.button(1, .off, .manual), receiveChannel: 5)
        model.performNonMotorTest(.button(1, .on, .manual))
        #expect(midi.sendAttempts == 0 && model.nonMotorTests.approval == nil)
        model.stopCapture()
    }

    @Test @MainActor func nonMotorPermissionIsRevokedByEveryRelevantLifecycleChange() throws {
        for action in 0 ..< 8 {
            let root = try temporaryEvidenceRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let (model, midi) = recordingModel(root)
            midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127)])
            model.armNonMotorTests(operatorFixture())
            #expect(model.nonMotorTests.approval != nil)
            switch action {
            case 0: model.stopCapture()
            case 1: model.selectPorts()
            case 2: model.configure()
            case 3: model.setLayer(.b)
            case 4: model.endHardwareObservation()
            case 5: model.resetHardwareObservation()
            case 6: midi.connect() // Even a same-ID reconnection requires new approval.
            default: model.setListenOnly(true)
            }
            #expect(model.nonMotorTests.approval == nil && model.listenOnly)
            #expect(model.session.state.isTouched(1))
            #expect(midi.sendAttempts == 0)
            model.stopCapture()
        }
    }

    @Test @MainActor func transportPinsDetectRouteAndEpochChangesBeforeUICallback() throws {
        for changeEpoch in [false, true] {
            let root = try temporaryEvidenceRoot(); defer { try? FileManager.default.removeItem(at: root) }
            let (model, midi) = recordingModel(root)
            model.armNonMotorTests(operatorFixture())
            let command = NonMotorTestCommand.ring(3, .allBlinking)
            model.previewNonMotorTest(command, receiveChannel: 5)
            if changeEpoch {
                midi.actualGeneration = 1
            } else {
                midi.actualOutputID = 99
            }
            model.performNonMotorTest(command)
            #expect(midi.sent.isEmpty)
            #expect(midi.sendAttempts == 1)
            #expect(model.nonMotorTests.approval == nil && model.listenOnly)
            #expect(model.nonMotorTests.attempts.first?.delivery == .failed)
            model.performNonMotorTest(command)
            #expect(midi.sendAttempts == 1) // No implicit retry after transport failure.
            model.stopCapture()
        }
    }

    @Test @MainActor func failedAuditPreventsPermissionOrCommandAndLocksOutput() {
        for failAtGrant in [true, false] {
            let midi = FakeMIDIService()
            let writer = ControlledEvidenceWriter()
            let model = ConsoleModel(startsMIDI: false, midi: midi, evidenceWriterFactory: { _ in writer })
            midi.connect(); model.beginHardwareObservation(); model.startCapture(URL(fileURLWithPath: "/not-written-fixture"))
            if failAtGrant {
                writer.failWrite = writer.writes + 1
            }
            model.armNonMotorTests(operatorFixture())
            if !failAtGrant {
                let command = NonMotorTestCommand.style(1, .pan)
                model.previewNonMotorTest(command, receiveChannel: 5)
                writer.failWrite = writer.writes + 1
                model.performNonMotorTest(command)
            }
            #expect(model.nonMotorTests.approval == nil && model.listenOnly)
            #expect(model.capturePath == nil && model.error != nil)
            #expect(midi.sendAttempts == 0)
        }
    }

    @Test @MainActor func physicalObservationsAreExplicitRouteBoundAndExportedSeparatelyFromDelivery() throws {
        let root = try temporaryEvidenceRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (model, midi) = recordingModel(root)
        model.armNonMotorTests(operatorFixture())
        for light in [ButtonLight.on, .blink] {
            let command = NonMotorTestCommand.button(2, light, .manual)
            model.previewNonMotorTest(command, receiveChannel: 5); model.performNonMotorTest(command)
        }
        let latest = try #require(model.nonMotorTests.attempts.first)
        let older = model.nonMotorTests.attempts[1]
        model.recordNonMotorObservation(older.id, result: .matches, note: "stale")
        #expect(model.nonMotorTests.attempts[1].observation == nil)
        model.recordNonMotorObservation(latest.id, result: .differs, note: "synthetic: steady instead of blink")
        #expect(model.nonMotorTests.attempts.first?.observation == .differs)
        #expect(model.panelSnapshot.button(2)?.light == .off)
        var reconnected = model.connection; reconnected.generation = 1
        midi.onConnection?(reconnected)
        model.recordNonMotorObservation(latest.id, result: .matches, note: "stale epoch")
        #expect(model.nonMotorTests.attempts.first?.observation == .differs)
        #expect(!model.panelSnapshot.nonMotorTests.canRecordObservation)
        model.stopCapture()
        let report = root.appendingPathComponent("review.json")
        model.exportInputReview(report)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: report)) as? [String: Any])
        let attempts = try #require(json["nonMotorAttempts"] as? [[String: Any]])
        #expect(attempts.first?["operatorReportedResponse"] as? String == "differs")
        #expect(json["hardwareAcceptance"] is NSNull)
        let rows = try String(contentsOf: root.appendingPathComponent("capture.jsonl"), encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(rows.contains { ($0["nonMotorTest"] as? [String: Any])?["operatorReportedResponse"] as? String == "differs" })
        #expect(midi.sent.count == 2)
    }

    @Test @MainActor func layerTestDoesNotAcknowledgeLayerOrDriveAnyMotorOnInput() throws {
        let root = try temporaryEvidenceRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let (model, midi) = recordingModel(root)
        model.armNonMotorTests(operatorFixture())
        model.previewNonMotorTest(.layer(.b), receiveChannel: 5)
        model.performNonMotorTest(.layer(.b))
        #expect(midi.sent == [.programChange(channel: 5, number: 1)])
        #expect(model.layer == .a)
        #expect(model.panelSnapshot.hardwareObservation?.inputLayer == nil)
        midi.onMessages?([.controlChange(channel: 0, number: 37, value: 42)])
        #expect(model.panelSnapshot.hardwareObservation?.inputLayer == .b)
        #expect(model.nonMotorTests.attempts.first?.observation == nil)
        #expect(midi.sent.count == 1)
        #expect(model.session.bank(.b).encoders[0] == 0)
        model.stopCapture()
    }

    @Test @MainActor func failedDeliveryAuditDoesNotRetractTransportFactOrRetryCommand() {
        let midi = FakeMIDIService()
        let writer = ControlledEvidenceWriter()
        let model = ConsoleModel(startsMIDI: false, midi: midi, evidenceWriterFactory: { _ in writer })
        midi.connect(); model.beginHardwareObservation(); model.startCapture(URL(fileURLWithPath: "/not-written-fixture"))
        model.armNonMotorTests(operatorFixture())
        let command = NonMotorTestCommand.button(1, .on, .manual)
        model.previewNonMotorTest(command, receiveChannel: 5)
        writer.failWrite = writer.writes + 2
        model.performNonMotorTest(command)
        #expect(midi.sendAttempts == 1 && midi.sent.count == 1)
        #expect(model.nonMotorTests.attempts.first?.delivery == .sent)
        #expect(model.nonMotorTests.attempts.first?.observation == nil)
        #expect(model.error != nil && model.capturePath == nil)
        #expect(model.listenOnly && model.nonMotorTests.approval == nil)
        model.performNonMotorTest(command)
        #expect(midi.sendAttempts == 1)
    }

    @Test @MainActor func failedWriteAheadFlushPreventsPermissionAndPhysicalSend() {
        for failAtGrant in [true, false] {
            let midi = FakeMIDIService()
            let writer = ControlledEvidenceWriter()
            let model = ConsoleModel(startsMIDI: false, midi: midi, evidenceWriterFactory: { _ in writer })
            midi.connect(); model.beginHardwareObservation(); model.startCapture(URL(fileURLWithPath: "/not-written-fixture"))
            writer.failFlush = failAtGrant
            model.armNonMotorTests(operatorFixture())
            if !failAtGrant {
                model.previewNonMotorTest(.style(1, .pan), receiveChannel: 5)
                writer.failFlush = true
                model.performNonMotorTest(.style(1, .pan))
            }
            #expect(midi.sendAttempts == 0)
            #expect(model.nonMotorTests.approval == nil && model.listenOnly)
            #expect(model.capturePath == nil && model.error != nil)
        }
    }
#endif
