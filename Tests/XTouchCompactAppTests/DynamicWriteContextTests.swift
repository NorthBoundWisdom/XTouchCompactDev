#if os(macOS)
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

    @MainActor private final class RoutedTestMIDI: RoutedMIDIService {
        var onMessages: (([MIDIMessage]) -> Void)?
        var onRoutedMessages: ((CompactMIDIInputEnvelope) -> Void)?
        var onConnection: ((CompactMIDIConnection) -> Void)?
        var sent: [MIDIMessage] = []
        func start() {}
        func select(inputID _: Int32?, outputID _: Int32?) {}
        func send(_ message: MIDIMessage) {
            sent.append(message)
        }

        func sendPinned(_ message: MIDIMessage, inputID _: Int32, outputID _: Int32, generation _: UInt64) {
            sent.append(message)
        }

        func connect(generation: UInt64, provenance: CompactEndpointProvenance) {
            let endpoint = CompactMIDIEndpoint(id: 1, name: "Same Device", provenance: provenance)
            onConnection?(.init(generation: generation, connectedInput: endpoint, connectedOutput: endpoint))
        }
    }

    @Test @MainActor func oldDynamicContextCannotBeReinstalledAfterRealRouteOrBindingChange() throws {
        let midi = RoutedTestMIDI()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(generation: 1, provenance: .remoteVirtual)
        let old = model.session.writeAuthorization
        try model.configureWriteAuthorization(old)
        midi.connect(generation: 2, provenance: .physicalUSB)
        #expect(throws: ParameterWriteAuthorizationError.staleContext) { try model.configureWriteAuthorization(old) }
        #expect(!model.session.writeAuthorization.allowsValues)
        var next = model.session.writeAuthorization; next.allowsValues = true
        try model.configureWriteAuthorization(next)
        model.apply { try $0.loadConfiguration($0.parameters.configuration) }
        #expect(throws: ParameterWriteAuthorizationError.staleContext) { try model.configureWriteAuthorization(next) }
        #expect(!model.session.writeAuthorization.allowsValues)
    }

    @Test @MainActor func authorityRefusalCorrectsUniqueProjectionAndChecksEachLaterRequest() throws {
        let model = ConsoleModel(startsMIDI: false, midi: FakeMIDIService(), isolated: true)
        let id = try #require(model.session.parameters.configuration.parameters.first?.id)
        var requests = 0
        model.parameterAuthority = { request in
            requests += 1
            return .init(accepted: false, actualValue: 10, routeGeneration: request.routeGeneration, bindingGeneration: request.bindingGeneration)
        }
        model.setParameter(id, value: 100)
        #expect(model.session.parameters.values[id] == 10)
        #expect(model.panelSnapshot.parameterValues[id] == 10)
        #expect(model.error.map { String(describing: $0).contains("authority_denied") } == true)
        #expect(!model.session.canUndo)
        model.setParameter(id, value: 90)
        #expect(requests == 2)
        #expect(model.session.parameters.values[id] == 10)
    }

    @Test @MainActor func inputEndpointEnvelopeKeepsOriginAndRejectsOldConnectionBeforeMutation() throws {
        let midi = RoutedTestMIDI()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(generation: 1, provenance: .remoteVirtual)
        model.setConsoleMode(.hardwareSend)
        let old = CompactEndpointStamp(endpoint: .init(id: 1, name: "Same Device", provenance: .remoteVirtual), generation: 1)
        midi.connect(generation: 2, provenance: .physicalUSB)
        let before = model.session.parameters.values
        let message = MIDIMessage.controlChange(channel: 0, number: 1, value: 100)
        midi.onRoutedMessages?(.init(messages: [message], origin: old))
        #expect(model.session.parameters.values == before)
        let stale = try #require(model.events.first { $0.direction == .input && $0.message == message })
        #expect(stale.ignored)
        #expect(stale.endpointOrigin == old)
        #expect(model.connection.connectedInput?.provenance == .physicalUSB)
        #expect(midi.sent.isEmpty)
    }
#endif

#if os(macOS)
    @Test @MainActor func dynamicGateRejectsGUIRemoteAndUndoThroughTheSameParameterOwner() throws {
        let model = ConsoleModel(startsMIDI: false, midi: FakeMIDIService(), isolated: true)
        let id = try #require(model.session.parameters.configuration.parameters.first?.id)
        model.setParameter(id, value: 100)
        var context = model.session.writeAuthorization; context.allowsValues = false
        try model.configureWriteAuthorization(context)
        let before = model.session.parameters.values
        model.setParameter(id, value: 20)
        #expect(model.error as? ParameterWriteAuthorizationError == .writesDenied)
        model.mcpWritesAllowed = true
        #expect(throws: ParameterWriteAuthorizationError.writesDenied) { try model.applyMCPBatch([.init(id: id, value: 20)]) }
        model.undo()
        #expect(model.error as? ParameterWriteAuthorizationError == .writesDenied)
        #expect(model.session.parameters.values == before)
        #expect(model.session.canUndo)
    }
#endif

#if os(macOS)
    @Test @MainActor func authorityCallbackCannotOverwriteSynchronousRevocationOrNewRoute() throws {
        for changeRoute in [false, true] {
            let midi = RoutedTestMIDI()
            let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
            midi.connect(generation: 1, provenance: .remoteVirtual)
            let id = try #require(model.session.parameters.configuration.parameters.first?.id)
            let before = model.session.parameters.values
            model.parameterAuthority = { request in
                if changeRoute {
                    midi.connect(generation: 2, provenance: .physicalUSB)
                } else {
                    var revoked = model.session.writeAuthorization; revoked.allowsValues = false
                    try model.configureWriteAuthorization(revoked)
                }
                return .init(accepted: true, actualValue: request.proposedValue,
                             routeGeneration: request.routeGeneration, bindingGeneration: request.bindingGeneration)
            }
            model.setParameter(id, value: 100)
            #expect(model.error as? ParameterWriteAuthorizationError == .staleContext)
            #expect(model.session.parameters.values == before)
            if changeRoute {
                #expect(model.session.writeAuthorization.routeGeneration == 2)
            } else {
                #expect(!model.session.writeAuthorization.allowsValues)
            }
            #expect(midi.sent.isEmpty)
        }
    }

    @Test @MainActor func deniedParameterBatchRetainsTouchAndOldLayerReleaseCannotUnlockMotors() throws {
        let midi = RoutedTestMIDI()
        let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
        midi.connect(generation: 1, provenance: .physicalUSB)
        model.setConsoleMode(.hardwareSend)
        var context = model.session.writeAuthorization; context.allowsValues = false
        #expect(context.allowsMechanisms)
        try model.configureWriteAuthorization(context)
        let origin = CompactEndpointStamp(endpoint: .init(id: 1, name: "Same Device", provenance: .physicalUSB), generation: 1)
        // Touch is actual safety evidence even though the following value write is denied.
        midi.onRoutedMessages?(.init(messages: [.controlChange(channel: 0, number: 101, value: 127),
                                                .controlChange(channel: 0, number: 1, value: 100)], origin: origin))
        #expect(model.session.state.isTouched(1))
        #expect(model.session.state.observedLayer == .a)
        #expect(model.error as? ParameterWriteAuthorizationError == .writesDenied)
        let count = midi.sent.count
        model.apply { try $0.setDisplayFader(1, value: 80) }
        #expect(midi.sent.count == count)
        // A release on the other layer must not grant motion on this host layer.
        midi.onRoutedMessages?(.init(messages: [.controlChange(channel: 0, number: 111, value: 0)], origin: origin))
        model.apply { try $0.setDisplayFader(1, value: 90) }
        #expect(midi.sent.count == count)
        #expect(model.session.state.layerMismatch)
        #expect(model.session.writeAuthorization.allowsMechanisms)
    }
#endif

#if os(macOS)
    @Test @MainActor func batchAuthorityCallbackRevalidatesEachEntryAgainstSynchronousRouteAndPermissionChanges() throws {
        for changeRoute in [false, true] {
            let midi = RoutedTestMIDI()
            let model = ConsoleModel(startsMIDI: false, midi: midi, isolated: true)
            midi.connect(generation: 1, provenance: .localVirtual)
            model.mcpWritesAllowed = true
            let ids = Array(model.session.parameters.configuration.parameters.prefix(2).map(\.id))
            #expect(ids.count == 2)
            let secondBefore = model.session.parameters.values[ids[1]]
            model.parameterAuthority = { request in
                if request.parameterID == ids[1] {
                    if changeRoute {
                        midi.connect(generation: 2, provenance: .physicalUSB)
                    } else {
                        var revoked = model.session.writeAuthorization; revoked.allowsValues = false
                        try model.configureWriteAuthorization(revoked)
                    }
                }
                return .init(accepted: true, actualValue: request.proposedValue,
                             routeGeneration: request.routeGeneration, bindingGeneration: request.bindingGeneration)
            }
            #expect(throws: ParameterWriteAuthorizationError.staleContext) {
                try model.applyMCPBatch([.init(id: ids[0], value: 100), .init(id: ids[1], value: 100)])
            }
            #expect(model.session.parameters.values[ids[0]] == 100)
            #expect(model.session.parameters.values[ids[1]] == secondBefore)
            if changeRoute {
                #expect(model.session.writeAuthorization.routeGeneration == 2)
            } else {
                #expect(!model.session.writeAuthorization.allowsValues)
            }
        }
    }
#endif
