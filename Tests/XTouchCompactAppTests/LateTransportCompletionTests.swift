#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @MainActor private func diagnosticConsole() -> (ConsoleModel, FakeMIDIService, ControlledEvidenceWriter) {
        let midi = FakeMIDIService()
        let writer = ControlledEvidenceWriter()
        let model = ConsoleModel(startsMIDI: false, midi: midi, now: { Date(timeIntervalSince1970: 123) }, isolated: true, evidenceWriterFactory: { _ in writer })
        midi.connect()
        model.beginHardwareObservation()
        model.startCapture(URL(fileURLWithPath: "/not-written-late-completion-fixture"))
        model.armNonMotorTests(.init(standardModeConfirmed: true, stage1Reviewed: true,
                                     stage1Evidence: "synthetic review", firmware: "synthetic firmware",
                                     receiveChannel: 5, receiveChannelEvidence: "synthetic independent RX setting"))
        model.previewNonMotorTest(.layer(.b), receiveChannel: 5)
        return (model, midi, writer)
    }

    @Test @MainActor func approvedSingleLayerCommandCannotEraseNewRouteObservationAfterTransportReturns() throws {
        let (model, midi, _) = diagnosticConsole()
        #expect(model.nonMotorTests.approval != nil)
        var observedInsideCallback: CompactLayer?
        midi.afterPinnedSend = {
            midi.actualGeneration = 1
            var replacement = model.connection; replacement.generation = 1
            midi.onConnection?(replacement)
            // A genuine input callback on the newly reported route, after the old send was accepted.
            midi.onMessages?([.controlChange(channel: 0, number: 37, value: 42)])
            observedInsideCallback = model.session.state.observedLayer
        }
        model.performNonMotorTest(.layer(.b))
        #expect(midi.sent == [.programChange(channel: 5, number: 1)])
        #expect(midi.sendAttempts == 1 && midi.unpinnedSendAttempts == 0)
        #expect(observedInsideCallback == .b)
        #expect(model.connection.generation == 1)
        #expect(model.session.state.observedLayer == .b)
        #expect(model.liveHardwareValues != nil)
        #expect(model.panelSnapshot.hardwareFeedbackNeedsSync == true)
        let output = try #require(model.events.first { $0.direction == .output && $0.delivery == .sent && $0.message == .programChange(channel: 5, number: 1) })
        #expect(output.endpointOrigin?.generation == 0)
        #expect(output.source == .hardware)
        print("LATE_IO_ROUTE_PROOF sendCount=\(midi.sent.count) oldGeneration=\(output.endpointOrigin?.generation ?? 999) currentGeneration=\(model.connection.generation) callbackObserved=\(String(describing: observedInsideCallback)) finalObserved=\(String(describing: model.session.state.observedLayer))")
        model.stopCapture()
    }

    @Test @MainActor func acceptedDiagnosticOutputKeepsSendTimeHostLayerAndDeviceLabelAcrossGUIModeChange() throws {
        let (model, midi, writer) = diagnosticConsole()
        #expect(model.layer == .a)
        midi.afterPinnedSend = {
            // Both are existing GUI intents. Observation remains passive and simulated feedback
            // goes only to the process-owned mock; no second physical command is requested.
            model.setLayer(.b)
            model.setConsoleMode(.mock)
        }
        model.performNonMotorTest(.layer(.b))
        #expect(midi.sent == [.programChange(channel: 5, number: 1)])
        #expect(midi.sendAttempts == 1 && midi.unpinnedSendAttempts == 0)
        #expect(!model.hardwareMode && model.layer == .b)
        let output = try #require(model.events.first { $0.direction == .output && $0.delivery == .sent && $0.nonMotorTest != nil && $0.message == .programChange(channel: 5, number: 1) })
        #expect(output.source == .hardware)
        #expect(output.endpointOrigin?.generation == 0)
        #expect(output.hostLayer == .a)
        #expect(output.text.key == "OUT %@")
        #expect(output.deviceSource == .hardware)
        let row = try #require(writer.rows.first { ($0["nonMotorTest"] as? [String: Any])?["phase"] as? String == "transport-result" && $0["delivery"] as? String == "sent" })
        #expect(row["hardwareMode"] as? Bool == true)
        #expect(row["listenOnly"] as? Bool == false)
        #expect(row["hostLayer"] as? String == "a")
        #expect(row["deviceSource"] as? String == "hardware")
        print("LATE_IO_LABEL_PROOF sendCount=\(midi.sent.count) actor=\(output.source.rawValue) recordedHostLayer=\(output.hostLayer.rawValue) currentHostLayer=\(model.layer.rawValue) label=\(output.text.key)")
        model.stopCapture()
    }

    @Test @MainActor func sameRouteLayerInputDuringAcceptedPCRemainsAMismatchAndBlocksExplicitRecall() {
        for touched in [false, true] {
            let (model, midi, _) = diagnosticConsole()
            midi.onMessages?([.controlChange(channel: 0, number: 1, value: 23)])
            #expect(model.liveHardwareValues?.faders[1]?.value == 23)
            midi.afterPinnedSend = {
                midi.afterPinnedSend = nil
                var input: [MIDIMessage] = [.controlChange(channel: 0, number: 37, value: 42)]
                if touched {
                    input.append(.controlChange(channel: 0, number: 111, value: 127))
                }
                midi.onMessages?(input)
            }
            model.performNonMotorTest(.layer(.b))
            #expect(midi.sent == [.programChange(channel: 5, number: 1)])
            #expect(model.connection.generation == 0)
            #expect(model.session.state.observedLayer == .b)
            #expect(model.session.state.layerMismatch)
            #expect(model.session.state.isTouched(1) == touched)
            #expect(model.liveHardwareValues?.encoders[.b]?[1]?.value == 42)
            #expect(model.liveHardwareValues?.faders[1] == nil) // The PC invalidates older facts.
            model.enableHardwareWriteback()
            model.recallMotors() // The real explicit GUI recall must still see the mismatch.
            #expect(midi.sent == [.programChange(channel: 5, number: 1)])
            model.stopCapture()
        }
    }
#endif
