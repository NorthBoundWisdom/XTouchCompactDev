import Foundation
import SurfaceControlContracts
import SurfaceDeviceContracts
import SurfaceFeedbackPlanning
import XTouchCompactCore

/// Core-primary preflight at the existing typed admission boundary. Both ordinary
/// and owned virtual hardware remain hardware/display-only compositions.
enum HardwareFeedbackRuntime {
    static func scope(_ origin: HardwareEndpointOrigin, configuration: CompactHardwareConfiguration, layer: CompactLayer) -> CompactFeedbackScope {
        var scope = CompactFeedbackScope()
        scope.inputID = origin.inputID; scope.outputID = origin.outputID; scope.transportGeneration = origin.connectionGeneration
        scope.connected = origin.inputID != nil && origin.outputID != nil; scope.hardwareMode = true
        scope.hostLayer = layer; scope.transmitChannel = configuration.transmitChannel; scope.receiveChannel = configuration.receiveChannel
        scope.lightProtocol = configuration.lightProtocol; scope.transportOrigin = origin.transportOrigin
        return scope
    }

    static func plan(_ message: HardwareDisplayMessage, index: Int, surface: CompactHardwareSurface, origin: HardwareEndpointOrigin,
                     request: ControlFeedback, writer: String?, at: Double) -> CompactFeedbackPlan
    {
        let config = surface.configuration
        let scope = scope(origin, configuration: config, layer: surface.observedLayer!)
        var reference = CompactFeedbackBytes(); reference.add(index); reference.add(String(reflecting: surface.controls.expected))
        var actor = CompactFeedbackBytes(); actor.add(writer); actor.add(writer ?? surface.remoteWriterID)
        var evidence = CompactFeedbackBytes(); evidence.add(String(reflecting: message)); evidence.add(String(reflecting: request)); evidence.add(at)
        evidence.add(origin.inputID != nil); if let id = origin.inputID {
            evidence.add(Int(id))
        }
        evidence.add(origin.outputID != nil); if let id = origin.outputID {
            evidence.add(Int(id))
        }
        evidence.add(origin.connectionGeneration); evidence.add(origin.transportOrigin)
        let endpoint = try! EndpointProvenance(endpointID: origin.outputID.map(String.init), deviceID: nil,
                                               connectionGeneration: origin.connectionGeneration,
                                               transportOrigin: EndpointTransportOrigin(rawValue: origin.transportOrigin)!)
        let wire = MIDI1UMPCodec.decode(try! message.word(configuration: config))!
        return try! CompactFeedbackPlanning.plan(wire, map: .init(transmitChannel: config.transmitChannel, globalReceiveChannel: config.receiveChannel), scope: scope,
                                                 reference: reference, origin: actor, source: .hardware, endpoint: endpoint, evidence: evidence)
    }

    static func currentScope(_ plan: CompactFeedbackPlan, origin: HardwareEndpointOrigin) -> CompactFeedbackScope {
        var scope = plan.scope; scope.inputID = origin.inputID; scope.outputID = origin.outputID
        scope.transportGeneration = origin.connectionGeneration; scope.connected = origin.inputID != nil && origin.outputID != nil; scope.transportOrigin = origin.transportOrigin
        return scope
    }

    static func preflight(_ plan: CompactFeedbackPlan, current: HardwareEndpointOrigin) throws {
        precondition(plan.requiredDirections == [.display])
        let snapshot = plan.capturedEvidence.dispatch
        let proof = CompactFeedbackProof(plan: plan, nativeSnapshot: snapshot, authorization: .granted(directions: [.display]), safety: .passed)
        let currentScope = currentScope(plan, origin: current)
        let decision = FeedbackPreflight.evaluate(plan: plan, proof: proof, currentScope: currentScope, currentNativeSnapshot: snapshot)
        #if DEBUG
            let native: FeedbackPreflight = currentScope == plan.scope ? .permitted : .rejected(.staleScope)
            CompactFeedbackShadow.preflight(plan: plan, proof: proof, currentScope: currentScope, currentNative: snapshot, native: native, audit: nil)
        #endif
        guard decision == .permitted else { throw ControlContractError("invalid_transition") }
    }

    #if DEBUG
        static func receipt(_ plan: CompactFeedbackPlan, result: FeedbackAttemptResult, current: HardwareEndpointOrigin, attempted: Bool, accepted: Bool) {
            let scope = currentScope(plan, origin: current)
            CompactFeedbackShadow.receipt(plan: plan, result: result, currentScope: scope, nativeCurrent: scope == plan.scope,
                                          attempted: attempted, accepted: accepted, audit: nil)
        }
    #endif
}
