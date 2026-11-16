#if os(macOS)
    import Combine
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @MainActor private final class PublicationMIDI: RoutedMIDIService {
        var onMessages: (([MIDIMessage]) -> Void)?
        var onRoutedMessages: ((CompactMIDIInputEnvelope) -> Void)?
        var onConnection: ((CompactMIDIConnection) -> Void)?
        var actual = CompactMIDIConnection()
        var sent: [MIDIMessage] = []
        var rejectedPins = 0
        var acceptedPins: [(Int32, Int32, UInt64)] = []
        func start() {}
        func select(inputID _: Int32?, outputID _: Int32?) {}
        func send(_ message: MIDIMessage) {
            sent.append(message)
        }

        func sendPinned(_ message: MIDIMessage, inputID: Int32, outputID: Int32, generation: UInt64) throws {
            guard actual.connectedInput?.id == inputID, actual.connectedOutput?.id == outputID, actual.generation == generation else {
                rejectedPins += 1; throw CompactMIDIError.routeChanged
            }
            sent.append(message)
            acceptedPins.append((inputID, outputID, generation))
        }

        func publish(_ snapshot: CompactMIDIConnection) {
            actual = snapshot; onConnection?(snapshot)
        }

        func emit(_ messages: [MIDIMessage], snapshot: CompactMIDIConnection, at: Double = 12) {
            onRoutedMessages?(.init(messages: messages, origin: .init(endpoint: snapshot.connectedInput, generation: snapshot.generation), at: at))
        }
    }

    @MainActor private func routeSnapshot(_ generation: UInt64, _ id: Int32, _ name: String, provenance: CompactEndpointProvenance = .localVirtual) -> CompactMIDIConnection {
        let endpoint = CompactMIDIEndpoint(id: id, name: name, provenance: provenance)
        return .init(generation: generation, connectedInput: endpoint, connectedOutput: endpoint)
    }

    @Test @MainActor func j3RoutePublicationWillSetCannotReplaceNewerTransportSnapshot() {
        let midi = PublicationMIDI()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true, eventMonotonicClock: { 12 })
        midi.publish(routeSnapshot(10, 1, "base")); model.setConsoleMode(.hardwareSend)
        let outer = routeSnapshot(11, 2, "outer"), inner = routeSnapshot(12, 3, "inner")
        var injected = false
        var observed: [String] = []
        let subscription = model.$connection.sink { incoming in
            guard !injected, incoming.generation == 11 else { return }
            injected = true
            observed.append("willSet incoming=\(incoming.generation) native-current=\(model.connection.generation)")
            midi.publish(inner)
            observed.append("after nested native-current=\(model.connection.generation)")
        }
        withExtendedLifetime(subscription) { midi.publish(outer) }
        #expect(injected)
        #expect(model.connection == midi.actual)
        #expect(model.connection.generation == 12)
        #expect(model.session.writeAuthorization.routeGeneration == 12)
        #expect(midi.sent.isEmpty)
        let before = model.session.parameters.values["a.Encoder.1"]
        midi.emit([.controlChange(channel: 0, number: 10, value: 31)], snapshot: outer)
        #expect(model.session.parameters.values["a.Encoder.1"] == before, "old captured IO must be rejected")
        midi.emit([.controlChange(channel: 0, number: 10, value: 47)], snapshot: inner)
        #expect(model.session.parameters.values["a.Encoder.1"] == 47, "latest captured IO must remain attached")
        let acceptedValue = model.session.parameters.values["a.Encoder.1"]
        print("J3_ROUTE_PUBLICATION case=connection actual=\(midi.actual.generation) model=\(model.connection.generation) auth=\(model.session.writeAuthorization.routeGeneration) input=\(String(describing: acceptedValue)) observations=\(observed)")
    }

    @Test @MainActor func j3RoutePermissionWillSetCannotResumeAnOlderConnectionNotification() {
        let midi = PublicationMIDI()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true, eventMonotonicClock: { 12 })
        midi.publish(routeSnapshot(10, 1, "base")); model.setConsoleMode(.hardwareSend); model.mcpMotorWritesAllowed = true
        let outer = routeSnapshot(11, 2, "outer"), inner = routeSnapshot(12, 3, "inner")
        var injected = false
        let subscription = model.$mcpMotorWritesAllowed.sink { incoming in
            guard !injected, !incoming else { return }
            injected = true
            midi.publish(inner)
        }
        withExtendedLifetime(subscription) { midi.publish(outer) }
        #expect(injected)
        #expect(model.connection == midi.actual)
        #expect(model.connection.generation == 12)
        #expect(model.session.writeAuthorization.routeGeneration == 12)
        #expect(!model.mcpMotorWritesAllowed)
        #expect(midi.sent.isEmpty)
        let before = model.session.parameters.values["a.Encoder.1"]
        midi.emit([.controlChange(channel: 0, number: 10, value: 31)], snapshot: outer)
        #expect(model.session.parameters.values["a.Encoder.1"] == before)
        midi.emit([.controlChange(channel: 0, number: 10, value: 47)], snapshot: inner)
        #expect(model.session.parameters.values["a.Encoder.1"] == 47)
        print("J3_ROUTE_PUBLICATION case=permission actual=\(midi.actual.generation) model=\(model.connection.generation) auth=\(model.session.writeAuthorization.routeGeneration)")
    }

    @Test @MainActor func j3RouteCosmeticWillSetPreservesNewerMetadataWithoutRevokingPendingIntent() {
        let midi = PublicationMIDI()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true, eventMonotonicClock: { 12 })
        let base = routeSnapshot(10, 1, "base")
        midi.publish(base); model.setConsoleMode(.hardwareSend)
        midi.emit([.controlChange(channel: 0, number: 101, value: 127)], snapshot: base)
        model.setParameter("a.Fader.1", value: 78)
        #expect(model.session.state.isMotorPending(1))
        let outer = routeSnapshot(10, 1, "outer", provenance: .physicalUSB)
        let inner = routeSnapshot(10, 1, "inner", provenance: .remoteVirtual)
        var injected = false
        let count = midi.sent.count
        let subscription = model.$connection.sink { incoming in
            guard !injected, incoming.connectedInput?.name == "outer" else { return }
            injected = true; midi.publish(inner)
        }
        withExtendedLifetime(subscription) { midi.publish(outer) }
        #expect(injected)
        #expect(model.connection == midi.actual)
        #expect(model.connection.connectedInput?.name == "inner")
        #expect(model.connection.connectedInput?.provenance == .remoteVirtual)
        #expect(model.session.state.isMotorPending(1))
        #expect(model.session.state.isTouched(1))
        #expect(midi.sent.count == count)
        print("J3_ROUTE_PUBLICATION case=cosmetic actual=\(midi.actual.connectedInput!.name) model=\(model.connection.connectedInput!.name) pending=\(model.session.state.isMotorPending(1))")
    }

    @Test @MainActor func j3HandoverReceiptsKeepCapturedScopeAndOnlyRecordPhysicalFactsOnce() {
        let midi = PublicationMIDI()
        let model = ConsoleModel(startsMIDI: false, midi: midi, now: { Date(timeIntervalSince1970: 100) }, isolated: true, eventMonotonicClock: { 200 })
        midi.publish(routeSnapshot(10, 1, "base")); model.setConsoleMode(.hardwareSend)
        let outer = routeSnapshot(11, 2, "outer"), inner = routeSnapshot(12, 3, "inner")
        var injected = false
        let beforeObservation = model.session.state.observationRevision
        let subscription = model.$connection.sink { incoming in
            guard !injected, incoming.generation == 11 else { return }
            injected = true
            midi.publish(inner)
            midi.emit([.controlChange(channel: 0, number: 10, value: 31)], snapshot: outer, at: 31.5)
            midi.emit([.controlChange(channel: 0, number: 1, value: 47), .controlChange(channel: 0, number: 101, value: 127),
                       .controlChange(channel: 0, number: 37, value: 61)], snapshot: inner, at: 42.75)
            model.recallMotors()
            model.setParameter("a.Fader.2", value: 50)
        }
        withExtendedLifetime(subscription) { midi.publish(outer) }
        #expect(injected && model.connection == inner)
        #expect(midi.sent.isEmpty)
        #expect(model.session.parameters.values["a.Fader.1"] == 0)
        #expect(model.session.parameters.values["a.Encoder.1"] == 0)
        #expect(model.session.state.observedFader(1) == 47)
        #expect(model.session.state.observedLayer == .b && model.session.state.layerMismatch)
        #expect(model.session.state.isTouched(1))
        #expect(model.session.state.observationRevision == beforeObservation + 3)
        let receiptEvents = model.events.filter { $0.direction == .input && $0.monotonicTime == 42.75 }
        #expect(receiptEvents.count == 3)
        for event in receiptEvents {
            #expect(event.endpointOrigin?.generation == 12 && event.endpointOrigin?.endpoint?.id == 3)
            #expect(event.timestamp == Date(timeIntervalSince1970: 100))
            #expect(event.hostLayer == .a && event.capturedHardwareLayer == nil)
            #expect(event.capturedBindingGeneration == 0 && event.ignored)
            #expect(event.deviceSource == .hardware && event.decodedInput != nil)
        }
        #expect(model.events.contains { $0.direction == .output && $0.delivery == .suppressed && $0.endpointOrigin?.generation == 12 })
        // A fresh normal input after stability follows the original business path exactly once.
        midi.emit([.controlChange(channel: 0, number: 10, value: 49)], snapshot: inner, at: 43)
        #expect(model.session.parameters.values["a.Encoder.1"] == 49)
        midi.emit([.controlChange(channel: 0, number: 101, value: 0)], snapshot: inner, at: 44)
        #expect(!model.session.state.isTouched(1))
        model.recallMotors()
        #expect(!midi.sent.isEmpty)
        #expect(!midi.acceptedPins.isEmpty)
        #expect(midi.acceptedPins.count == midi.sent.count, "Every physical send must have a recorded successful pin")
        #expect(midi.acceptedPins.allSatisfy { $0.0 == 3 && $0.1 == 3 && $0.2 == 12 })
        print("J3_PIN_RECORDER case=receipt pins=\(midi.acceptedPins.count) sends=\(midi.sent.count) expected=3/3/12 actual=\(midi.acceptedPins)")
        print("J3_ROUTE_HANDOVER receipts=3 observations=3 physical_fader=47 business_fader=0 old_origin_rejected=true stable_positive_input=49")
    }

    @Test @MainActor func j3HandoverLimitsYieldAndFailClosedWithoutLosingKnownTouch() async {
        let midi = PublicationMIDI()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true, eventMonotonicClock: { 12 })
        let base = routeSnapshot(10, 1, "base")
        midi.publish(base); model.setConsoleMode(.hardwareSend); model.mcpMotorWritesAllowed = true
        midi.emit([.controlChange(channel: 0, number: 101, value: 127)], snapshot: base)
        model.setParameter("a.Fader.1", value: 78)
        #expect(model.session.state.isTouched(1) && model.session.state.isMotorPending(1))
        var emitted = 0
        var flooded = false
        let subscription = model.$connection.sink { incoming in
            guard incoming.generation >= 11, emitted < 20 else { return }
            emitted += 1
            let next = routeSnapshot(incoming.generation + 1, 1, "cascade")
            midi.publish(next)
            if !flooded {
                flooded = true
                for _ in 0 ..< 65 {
                    midi.emit([.controlChange(channel: 0, number: 101, value: 127)], snapshot: next, at: 51)
                }
                // An unattributed legacy batch cannot be relabeled with the pending route.
                midi.onMessages?([.controlChange(channel: 0, number: 10, value: 99)])
            }
        }
        withExtendedLifetime(subscription) { midi.publish(routeSnapshot(11, 1, "outer")) }
        #expect(emitted <= 16, "One synchronous drain must yield at its bounded notification limit")
        #expect(model.session.state.isTouched(1))
        #expect(!model.mcpMotorWritesAllowed)
        #expect(midi.sent.isEmpty)
        model.recallMotors()
        #expect(midi.sent.isEmpty)
        // Wait only for this one finite already-issued notification chain, without retrying actions.
        for _ in 0 ..< 64 where model.connection != midi.actual {
            await Task.yield()
        }
        #expect(emitted == 20 && model.connection == midi.actual)
        #expect(model.session.writeAuthorization.routeGeneration == midi.actual.generation)
        #expect(model.session.state.isTouched(1))
        #expect(model.session.state.pendingMotorFacts.isEmpty)
        #expect(model.session.parameters.values["a.Encoder.1"] == 0)
        #expect(model.events.contains { $0.ignored && $0.text.key.contains("handover") })
        #expect(midi.sent.isEmpty)
        // Stability does not replay dropped effects or silently restore Agent motor permission.
        model.setParameter("a.Fader.2", value: 63)
        #expect(midi.sent.isEmpty)
        #expect(!model.mcpMotorWritesAllowed)
        model.recallMotors()
        #expect(!midi.sent.contains {
            if case .controlChange(_, 1, _) = $0 {
                true
            } else {
                false
            }
        }, "The known touched fader must never move")
        #expect(!midi.sent.contains {
            if case .programChange = $0 {
                true
            } else {
                false
            }
        })
        #expect(model.session.state.isTouched(1))
        #expect(!midi.acceptedPins.isEmpty)
        #expect(midi.acceptedPins.count == midi.sent.count, "Every physical send must have a recorded successful pin")
        #expect(midi.acceptedPins.allSatisfy { $0.0 == midi.actual.connectedInput?.id && $0.1 == midi.actual.connectedOutput?.id && $0.2 == midi.actual.generation })
        withExtendedLifetime(subscription) {}
        print("J3_PIN_RECORDER case=overload pins=\(midi.acceptedPins.count) sends=\(midi.sent.count) expected=\(midi.actual.connectedInput!.id)/\(midi.actual.connectedOutput!.id)/\(midi.actual.generation) actual=\(midi.acceptedPins)")
        print("J3_ROUTE_HANDOVER overload_emissions=\(emitted) latest_generation=\(model.connection.generation) motor_permission=false known_touch_preserved=true automatic_sends=0 explicit_untouched_sends=\(midi.sent.count) touched_fader_sends=0")
    }

    @Test @MainActor func j3HandoverDoesNotQuarantineTheIndependentMockSurface() {
        let midi = PublicationMIDI()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true, eventMonotonicClock: { 12 })
        midi.publish(routeSnapshot(10, 1, "base"))
        var injected = false
        let subscription = model.$connection.sink { incoming in
            guard !injected, incoming.generation == 11 else { return }
            injected = true
            midi.publish(routeSnapshot(12, 3, "inner"))
            model.setParameter("a.Fader.1", value: 69)
        }
        withExtendedLifetime(subscription) { midi.publish(routeSnapshot(11, 2, "outer")) }
        #expect(injected && !model.hardwareMode)
        #expect(model.session.parameters.values["a.Fader.1"] == 69)
        #expect(model.events.contains { $0.direction == .output && $0.delivery == .sent && $0.deviceSource == .simulation })
        #expect(midi.sent.isEmpty)
        #expect(model.connection == midi.actual)
        print("J3_ROUTE_HANDOVER mock_value=69 mock_sent=true hardware_sends=0")
    }

    @Test @MainActor func j3CosmeticPublicationKeepsNormalHardwareInputAndDisplayIO() {
        let midi = PublicationMIDI()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true, eventMonotonicClock: { 12 })
        let base = routeSnapshot(10, 1, "base")
        midi.publish(base); model.setConsoleMode(.hardwareSend)
        var injected = false
        let subscription = model.$connection.sink { incoming in
            guard !injected, incoming.connectedInput?.name == "cosmetic" else { return }
            injected = true
            midi.emit([.controlChange(channel: 0, number: 10, value: 64)], snapshot: base, at: 91)
        }
        withExtendedLifetime(subscription) { midi.publish(routeSnapshot(10, 1, "cosmetic", provenance: .remoteVirtual)) }
        #expect(injected)
        #expect(model.session.parameters.values["a.Encoder.1"] == 64)
        #expect(model.session.writeAuthorization.routeGeneration == 10)
        #expect(!midi.sent.isEmpty)
        #expect(model.events.contains { $0.direction == .output && $0.delivery == .sent && $0.deviceSource == .hardware })
        #expect(!model.events.contains { $0.direction == .input && $0.monotonicTime == 91 && $0.ignored })
        print("J3_ROUTE_HANDOVER cosmetic_business_input=64 display_io_preserved=true epoch=10")
    }

    @Test @MainActor func j3HandoverObservationDrainDoesNotReplayOldLayerFactsOverNewInput() {
        let midi = PublicationMIDI()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true, eventMonotonicClock: { 12 })
        midi.publish(routeSnapshot(10, 1, "base")); model.setConsoleMode(.hardwareSend)
        let outer = routeSnapshot(11, 2, "outer"), inner = routeSnapshot(12, 3, "inner")
        var connectionInjected = false, physicalInjected = false
        let observationBefore = model.session.state.observationRevision
        let physical = model.$liveHardwareValues.sink { value in
            guard !physicalInjected, value != nil, model.connection.generation == 12 else { return }
            physicalInjected = true
            // A later positive B input and old-A release arrive while older A observations drain.
            midi.emit([.controlChange(channel: 0, number: 37, value: 70), .controlChange(channel: 0, number: 101, value: 0)], snapshot: inner, at: 45)
            model.recallMotors()
        }
        let connection = model.$connection.sink { incoming in
            guard !connectionInjected, incoming.generation == 11 else { return }
            connectionInjected = true; midi.publish(inner)
            midi.emit([.controlChange(channel: 0, number: 1, value: 47), .controlChange(channel: 0, number: 101, value: 127)], snapshot: inner, at: 42)
        }
        withExtendedLifetime((physical, connection)) { midi.publish(outer) }
        #expect(connectionInjected && physicalInjected)
        #expect(model.session.state.observedLayer == .b && model.session.state.layerMismatch)
        #expect(model.session.state.observationRevision == observationBefore + 4)
        #expect(model.session.parameters.values["a.Fader.1"] == 0)
        #expect(model.session.parameters.values["b.Encoder.1"] == 0)
        #expect(midi.sent.isEmpty)
        model.recallMotors()
        #expect(midi.sent.isEmpty, "The newer B mismatch must survive old A contact release and old queued observations")
        #expect(model.events.filter { $0.direction == .input && $0.monotonicTime == 42 }.count == 2)
        #expect(model.events.filter { $0.direction == .input && $0.monotonicTime == 45 }.count == 2)
        print("J3_ROUTE_HANDOVER older_then_newer_observations=4 latest_layer=b mismatch=true explicit_sends=0")
    }
#endif
