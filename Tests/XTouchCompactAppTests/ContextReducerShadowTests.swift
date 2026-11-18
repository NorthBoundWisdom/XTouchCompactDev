#if os(macOS)
    import Combine
    import Foundation
    import SurfaceConnectionState
    import Testing
    @testable import XTouchCompactApp
    @testable import XTouchCompactCore

    @Test @MainActor func cosmeticRouteRetainsIntentsButRealReplacementRevokesThem() {
        let midi = FakeMIDIService()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true, eventMonotonicClock: { 12 })
        midi.connect(); model.setConsoleMode(.hardwareSend)
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127)])
        model.setParameter("a.Fader.1", value: 83)
        #expect(model.session.state.isMotorPending(1))
        let count = midi.sent.count
        let renamed = CompactMIDIEndpoint(id: 1, name: "Cosmetic description changed", provenance: .remoteVirtual)
        midi.onConnection?(.init(connectedInput: renamed, connectedOutput: renamed))
        #expect(model.session.state.isMotorPending(1))
        #expect(model.session.state.isTouched(1))
        #expect(midi.sent.count == count)
        #expect(model.connection.connectedInput?.provenance == .remoteVirtual)
        midi.onMessages?([.controlChange(channel: 0, number: 101, value: 0)])
        model.setParameter("a.Fader.1", value: 33)
        var replaced = false
        midi.afterPinnedSend = {
            guard !replaced else { return }
            replaced = true
            midi.actualGeneration = 1
            midi.actualInputID = 2; midi.actualOutputID = 2
            let endpoint = CompactMIDIEndpoint(id: 2, name: "New route")
            midi.onConnection?(.init(generation: 1, connectedInput: endpoint, connectedOutput: endpoint))
        }
        model.recallMotors()
        midi.afterPinnedSend = nil
        #expect(replaced)
        #expect(model.connection.generation == 1)
        #expect(model.session.state.pendingMotorFacts.isEmpty)
        #expect(model.hardwareFeedbackNeedsSync)
    }

    @Test @MainActor func callbackBindingOrTouchMutationRevokesCandidateAuthority() {
        for changesBinding in [false, true] {
            let midi = FakeMIDIService()
            let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true, eventMonotonicClock: { 12 })
            midi.connect(); model.setConsoleMode(.hardwareSend)
            midi.onMessages?([.controlChange(channel: 0, number: 25, value: 0)])
            let before = model.session.parameters.values["a.Fader.1"]
            model.parameterAuthority = { request in
                model.parameterAuthority = nil
                if changesBinding {
                    model.apply { try $0.loadConfiguration(.neutral) }
                }
                midi.onMessages?([.controlChange(channel: 0, number: 101, value: 127)])
                return .init(accepted: true, actualValue: request.proposedValue, routeGeneration: request.routeGeneration, bindingGeneration: request.bindingGeneration)
            }
            model.setParameter("a.Fader.1", value: 91)
            #expect(model.error as? ParameterWriteAuthorizationError == .staleContext)
            #expect(model.session.parameters.values["a.Fader.1"] == before)
            #expect(model.session.state.isTouched(1))
            let sentBefore = midi.sent.count
            model.recallMotors()
            let newCommands = midi.sent.dropFirst(sentBefore)
            #expect(!newCommands.contains {
                if case .controlChange(_, 1, _) = $0 {
                    true
                } else {
                    false
                }
            })
        }
    }

    @Test @MainActor func connectionPublishesOnlyAtActualNativeStoreBoundaries() {
        for phase in ["permission", "connection", "cosmetic"] {
            let midi = FakeMIDIService()
            let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true, eventMonotonicClock: { 12 })
            midi.connect(); model.setConsoleMode(.hardwareSend); model.mcpMotorWritesAllowed = true
            let cosmetic = phase == "cosmetic"
            let outerEndpoint = CompactMIDIEndpoint(id: cosmetic ? 1 : 2, name: "outer", provenance: .physicalUSB)
            let innerEndpoint = CompactMIDIEndpoint(id: cosmetic ? 1 : 3, name: "inner", provenance: .remoteVirtual)
            let outer = CompactMIDIConnection(generation: cosmetic ? 0 : 1, connectedInput: outerEndpoint, connectedOutput: outerEndpoint)
            let inner = CompactMIDIConnection(generation: cosmetic ? 0 : 2, connectedInput: innerEndpoint, connectedOutput: innerEndpoint)
            let previous = model.connection
            var phases: [CompactMIDIConnection] = []
            var injected = false
            func publish(_ snapshot: CompactMIDIConnection) {
                midi.actualInputID = snapshot.connectedInput?.id
                midi.actualOutputID = snapshot.connectedOutput?.id
                midi.actualGeneration = snapshot.generation
                midi.onConnection?(snapshot)
            }
            let capture: () -> Void = {
                guard !injected else { return }
                injected = true
                phases.append(model.connection)
                publish(inner)
                phases.append(model.connection)
            }
            let subscription: AnyCancellable = if phase == "permission" {
                model.$mcpMotorWritesAllowed.sink {
                    value in if !value {
                        capture()
                    }
                }
            } else {
                model.$connection.sink {
                    value in if value.connectedInput?.name == "outer" {
                        capture()
                    }
                }
            }
            withExtendedLifetime(subscription) { publish(outer) }
            phases.append(model.connection)
            #expect(injected && phases == [previous, previous, inner])
            #expect(model.connection == inner)
            #expect(model.session.writeAuthorization.routeGeneration == inner.generation)
            #expect(midi.sent.isEmpty)
        }
    }
#endif
