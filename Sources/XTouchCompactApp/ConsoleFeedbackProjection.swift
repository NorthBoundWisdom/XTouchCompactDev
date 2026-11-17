#if os(macOS)
    import Foundation
    import SurfaceDeviceContracts
    import SurfaceFeedbackPlanning
    import XTouchCompactCore

    enum ConsoleFeedbackProjection {
        static func evidence(_ route: CompactMIDIConnection, output: CompactEndpointStamp,
                             planned _: CompactPlannedProvenance?, knownLayer: CompactLayer?,
                             at: Double, authorizedTest: AuthorizedNonMotorTest?) -> CompactFeedbackBytes
        {
            var value = CompactFeedbackBytes()
            func endpoint(_ endpoint: CompactMIDIEndpoint?, into value: inout CompactFeedbackBytes) {
                value.add(endpoint != nil)
                if let endpoint {
                    value.add(Int(endpoint.id)); value.add(endpoint.name)
                    value.add(endpoint.provenance.rawValue); value.add(endpoint.qualification.rawValue)
                }
            }
            value.add(route.generation)
            for endpoints in [route.inputs, route.outputs] {
                value.add(endpoints.count)
                for item in endpoints {
                    endpoint(item, into: &value)
                }
            }
            endpoint(route.connectedInput, into: &value); endpoint(route.connectedOutput, into: &value)
            value.add(route.error != nil)
            if let error = route.error {
                value.add(error.key); value.add(error.arguments.count)
                for argument in error.arguments {
                    value.add(argument)
                }
                let localized = error.localizedArgumentIndices.sorted(); value.add(localized.count)
                for index in localized {
                    value.add(index)
                }
            }
            endpoint(output.endpoint, into: &value); value.add(output.generation)
            value.add(knownLayer?.rawValue); value.add(at)
            value.add(authorizedTest != nil)
            if let authorizedTest {
                value.add(String(reflecting: authorizedTest))
            }
            return value
        }

        static func plan(_ message: MIDIMessage, index: Int, actor: MonitorEvent.Source,
                         scope: CompactFeedbackScope, route: CompactMIDIConnection,
                         output: CompactEndpointStamp, planned: CompactPlannedProvenance?,
                         knownLayer: CompactLayer?, map: FactoryStandardMap, at: Double,
                         authorizedTest: AuthorizedNonMotorTest?) -> CompactFeedbackPlan
        {
            let source: SurfaceDeviceContracts.DeviceSource = scope.hardwareMode ? .hardware : .simulation
            let endpoint = try! ConsoleNeutralProjection.endpoint(output)
            let context = try! CompactNeutralProjection.context(instanceID: "feedback.dispatch", routeGeneration: route.generation,
                                                                bindingGeneration: scope.authorization!.bindingGeneration,
                                                                hostLayer: scope.hostLayer, knownHardwareLayer: knownLayer)
            let effect = try? CompactNeutralProjection.feedback(message, map: map, hostLayer: scope.hostLayer,
                                                                effectID: "feedback.dispatch", context: context, endpoint: endpoint, source: source, at: at)
            var reference = CompactFeedbackBytes(); reference.add(index); reference.add(planned)
            var origin = CompactFeedbackBytes(); origin.add(actor.rawValue)
            var queued = CompactFeedbackBytes(); queued.add(planned)
            var fullEvidence = evidence(route, output: output, planned: planned, knownLayer: knownLayer, at: at, authorizedTest: authorizedTest)
            fullEvidence.add(scope)
            return try! .init(reference: reference, payload: message, origin: origin, scope: scope, source: source,
                              endpointEvidence: endpoint,
                              capturedEvidence: .init(dispatch: fullEvidence, planned: queued),
                              targetID: effect?.targetID ?? "native.unclassified", affectedElements: effect?.affectedElements ?? [],
                              classification: effect?.classification ?? .display, sideEffects: effect?.sideEffects ?? [], deliveryMode: .direct)
        }
    }
#endif
