#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @MainActor private final class AuditAuthorityMIDI: RoutedMIDIService {
        var onMessages: (([MIDIMessage]) -> Void)?
        var onRoutedMessages: ((CompactMIDIInputEnvelope) -> Void)?
        var onConnection: ((CompactMIDIConnection) -> Void)?
        var sent: [MIDIMessage] = []
        var starts = 0
        let endpoint = CompactMIDIEndpoint(id: 1, name: "audit-owned-virtual", provenance: .localVirtual)
        func start() {
            starts += 1
        }

        func select(inputID _: Int32?, outputID _: Int32?) {}
        func send(_ message: MIDIMessage) {
            sent.append(message)
        }

        func sendPinned(_ message: MIDIMessage, inputID: Int32, outputID: Int32, generation: UInt64) throws {
            guard inputID == 1, outputID == 1, generation == 1 else { throw CompactMIDIError.routeChanged }
            sent.append(message)
        }

        func connect() {
            onConnection?(.init(generation: 1, connectedInput: endpoint, connectedOutput: endpoint))
        }

        func emit(_ messages: [MIDIMessage]) {
            onRoutedMessages?(.init(messages: messages, origin: .init(endpoint: endpoint, generation: 1), at: 12))
        }
    }

    private enum AuditEntry: String, CaseIterable { case gui, agent, input, undo, redo, scene }

    @MainActor private func auditAuthorityConsole(_ entry: AuditEntry) throws -> (ConsoleModel, AuditAuthorityMIDI) {
        let midi = AuditAuthorityMIDI()
        let model = ConsoleModel(startsMIDI: false, midi: midi, now: { Date(timeIntervalSince1970: 100) }, isolated: true, eventMonotonicClock: { 12 })
        midi.connect(); model.setConsoleMode(.hardwareSend); model.mcpMotorWritesAllowed = true; model.mcpWritesAllowed = true
        midi.emit([.controlChange(channel: 0, number: 25, value: 0)])
        if entry == .scene {
            model.apply { try $0.captureScene(id: "baseline", name: "Baseline"); return [] }
        }
        if [.undo, .redo, .scene].contains(entry) {
            model.setParameter("a.Fader.1", value: 80)
        }
        if entry == .redo {
            model.undo()
        }
        midi.sent.removeAll(); model.dismissNotification("runtime")
        return (model, midi)
    }

    @MainActor private func invokeAuditEntry(_ entry: AuditEntry, _ model: ConsoleModel, _ midi: AuditAuthorityMIDI) -> (any Error)? {
        do {
            switch entry {
            case .gui: model.setParameter("a.Fader.1", value: 80)
            case .agent: try model.applyAgentParameter("a.Fader.1", value: 80)
            case .input: midi.emit([.controlChange(channel: 0, number: 1, value: 80)])
            case .undo: model.undo()
            case .redo: model.redo()
            case .scene: model.recallScene("baseline")
            }
        } catch { return error }
        return model.error
    }

    @Test @MainActor func authoritySameRouteTouchCannotBeOverwrittenByAnyCandidateEntry() throws {
        for entry in AuditEntry.allCases {
            let (model, midi) = try auditAuthorityConsole(entry)
            model.parameterAuthority = { request in
                model.parameterAuthority = nil
                midi.emit([.controlChange(channel: 0, number: 101, value: 127)])
                return .init(accepted: true, actualValue: request.proposedValue, routeGeneration: request.routeGeneration, bindingGeneration: request.bindingGeneration)
            }
            let error = invokeAuditEntry(entry, model, midi)
            #expect(model.session.state.isTouched(1), "entry=\(entry.rawValue)")
            #expect(error as? ParameterWriteAuthorizationError == .staleContext, "entry=\(entry.rawValue)")
            #expect(!midi.sent.contains {
                if case .controlChange(_, 1, _) = $0 {
                    true
                } else {
                    false
                }
            }, "entry=\(entry.rawValue)")
            model.recallMotors()
            #expect(!midi.sent.contains {
                if case .controlChange(_, 1, _) = $0 {
                    true
                } else {
                    false
                }
            }, "explicit recall entry=\(entry.rawValue)")
            let attempts = midi.sent.count
            model.setLayer(.b)
            #expect(midi.sent.count == attempts, "global touched layer gate entry=\(entry.rawValue)")
            #expect(midi.starts == 0)
        }
    }

    @Test @MainActor func authoritySameRouteLayerEvidenceAndOldLayerReleaseSurviveEveryCandidateEntry() throws {
        for entry in AuditEntry.allCases {
            let (model, midi) = try auditAuthorityConsole(entry)
            model.parameterAuthority = { request in
                model.parameterAuthority = nil
                midi.emit([.controlChange(channel: 0, number: 37, value: 42)])
                return .init(accepted: true, actualValue: request.proposedValue, routeGeneration: request.routeGeneration, bindingGeneration: request.bindingGeneration)
            }
            let error = invokeAuditEntry(entry, model, midi)
            #expect(model.session.state.observedLayer == .b && model.session.state.layerMismatch, "entry=\(entry.rawValue)")
            #expect(error as? ParameterWriteAuthorizationError == .staleContext, "entry=\(entry.rawValue)")
            midi.emit([.controlChange(channel: 0, number: 101, value: 0)])
            #expect(model.session.state.observedLayer == .b && model.session.state.layerMismatch, "old release entry=\(entry.rawValue)")
            let attempts = midi.sent.count
            model.recallMotors()
            #expect(midi.sent.count == attempts, "explicit recall entry=\(entry.rawValue)")
        }
    }

    @Test @MainActor func authorityNestedSameScopeMutationRemainsCanonicalAndOuterProposalIsRejected() throws {
        for entry in AuditEntry.allCases {
            let (model, midi) = try auditAuthorityConsole(entry)
            model.parameterAuthority = { request in
                model.parameterAuthority = nil
                model.setParameter("a.Fader.1", value: 33)
                return .init(accepted: true, actualValue: request.proposedValue, routeGeneration: request.routeGeneration, bindingGeneration: request.bindingGeneration)
            }
            let error = invokeAuditEntry(entry, model, midi)
            #expect(model.session.parameters.values["a.Fader.1"] == 33, "entry=\(entry.rawValue)")
            #expect(error as? ParameterWriteAuthorizationError == .staleContext, "entry=\(entry.rawValue)")
            #expect(!midi.sent.contains {
                if case let .controlChange(_, 1, value) = $0 {
                    value != 33
                } else {
                    false
                }
            }, "entry=\(entry.rawValue)")
            let faderAttempts = midi.sent.filter {
                if case .controlChange(_, 1, _) = $0 {
                    true
                } else {
                    false
                }
            }.count
            model.recallMotors()
            #expect(midi.sent.filter {
                if case .controlChange(_, 1, _) = $0 {
                    true
                } else {
                    false
                }
            }.count == faderAttempts, "older input must not be replayed as fresh after nested send entry=\(entry.rawValue)")
        }
    }

    @Test @MainActor func authorityReadOnlyQueriesDoNotRejectAnOtherwiseValidCandidate() throws {
        for entry in AuditEntry.allCases {
            let (model, midi) = try auditAuthorityConsole(entry)
            var reads = 0
            model.parameterAuthority = { request in
                _ = model.panelSnapshot.parameterValues
                _ = model.session.state.isTouched(1)
                _ = model.session.bank(.a)
                reads += 1
                return .init(accepted: true, actualValue: request.proposedValue, routeGeneration: request.routeGeneration, bindingGeneration: request.bindingGeneration)
            }
            #expect(invokeAuditEntry(entry, model, midi) == nil, "entry=\(entry.rawValue)")
            #expect(reads > 0)
        }
    }
#endif
