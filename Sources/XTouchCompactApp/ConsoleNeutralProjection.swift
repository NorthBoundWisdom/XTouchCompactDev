#if os(macOS)
    import Foundation
    import SurfaceDeviceContracts
    import XTouchCompactCore

    /// Projects only creation-time facts. It neither reads the current model nor performs input/IO.
    enum ConsoleNeutralProjection {
        static func source(_ event: MonitorEvent) throws -> SurfaceDeviceContracts.DeviceSource {
            guard let source = event.deviceSource else { throw CompactNeutralProjectionError.missingCapturedFact("deviceSource") }
            return source == .hardware ? .hardware : .simulation
        }

        static func endpoint(_ stamp: CompactEndpointStamp?) throws -> EndpointProvenance {
            guard let stamp else { throw CompactNeutralProjectionError.missingCapturedFact("endpoint") }
            let origin: EndpointTransportOrigin = switch stamp.endpoint?.provenance ?? .unknown {
            case .unknown: .unknown
            case .physicalUSB: .physicalUSB
            case .localVirtual: .localVirtual
            case .remoteVirtual: .remoteVirtual
            }
            return try .init(endpointID: stamp.endpoint.map { String($0.id) }, deviceID: nil,
                             connectionGeneration: stamp.generation, transportOrigin: origin)
        }

        static func context(_ event: MonitorEvent, instanceID: String) throws -> DeviceContext {
            guard let binding = event.capturedBindingGeneration, let stamp = event.endpointOrigin else {
                throw CompactNeutralProjectionError.missingCapturedFact("context")
            }
            return try CompactNeutralProjection.context(instanceID: instanceID, routeGeneration: stamp.generation,
                                                        bindingGeneration: binding, hostLayer: event.hostLayer,
                                                        inputFacet: event.deviceLayer, knownHardwareLayer: event.capturedHardwareLayer, hardwareEvidenceIsPrior: event.direction == .input)
        }

        static func input(_ event: MonitorEvent, instanceID: String) throws -> DeviceInputEvent? {
            guard event.direction == .input, let input = event.decodedInput else { return nil } // Actual undecoded transport remains diagnostic evidence.
            guard let at = event.monotonicTime else { throw CompactNeutralProjectionError.missingCapturedFact("monotonicTime") }
            return try CompactNeutralProjection.input(input, context: context(event, instanceID: instanceID),
                                                      endpoint: endpoint(event.endpointOrigin), source: source(event), at: at)
        }

        static func feedback(_ event: MonitorEvent, instanceID: String) throws -> EffectDescriptor? {
            guard event.direction == .output else { return nil }
            guard let message = event.message, let dispatch = event.dispatchContext, let at = event.monotonicTime else {
                throw CompactNeutralProjectionError.missingCapturedFact("dispatch")
            }
            let map = try FactoryStandardMap(transmitChannel: dispatch.transmitChannel, globalReceiveChannel: dispatch.receiveChannel)
            return try CompactNeutralProjection.feedback(message, map: map, hostLayer: event.hostLayer,
                                                         effectID: "native-event." + event.id.uuidString,
                                                         context: context(event, instanceID: instanceID), endpoint: endpoint(event.endpointOrigin),
                                                         source: source(event), at: at)
        }

        static func transmission(_ event: MonitorEvent, effect: EffectDescriptor) throws -> TransmissionEvidence? {
            let outcome: TransmissionOutcome
            switch event.delivery {
            case .sent: outcome = .accepted
            case .failed:
                // A pre-dispatch route rejection has no actual transport completion evidence.
                guard event.transportMonotonicTime != nil else { return nil }
                outcome = .rejected(reason: "native_transport_rejected")
            default: return nil
            }
            guard let completedAt = event.transportMonotonicTime else { throw CompactNeutralProjectionError.missingCapturedFact("transportTime") }
            return try .init(effectID: effect.id, targetID: effect.targetID, context: effect.context,
                             endpoint: effect.endpoint, source: effect.source, at: completedAt, outcome: outcome)
        }
    }
#endif
