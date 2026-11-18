import SurfaceControlContracts
import SurfaceDeviceContracts
import SurfaceFeedbackPlanning
import XTouchCompactCore

/// The request passed the surface display policy. Only typed display output can reach a sender.
struct HardwareDisplayAdmission {
    typealias Plan = FeedbackPlan<HardwareDisplayMessage, CompactFeedbackBytes, HardwareEndpointOrigin, Int, CompactFeedbackBytes>
    let plan: Plan

    init(_ message: HardwareDisplayMessage, index: Int, request: ControlFeedback, writer: String?, fallbackWriter: String,
         origin: HardwareEndpointOrigin, at: Double) throws
    {
        var actor = CompactFeedbackBytes(); actor.add(writer); actor.add(writer ?? fallbackWriter)
        var evidence = CompactFeedbackBytes(); evidence.add(String(reflecting: request)); evidence.add(at)
        let endpoint = try EndpointProvenance(endpointID: origin.outputID.map(String.init), deviceID: nil,
                                              connectionGeneration: origin.connectionGeneration,
                                              transportOrigin: EndpointTransportOrigin(rawValue: origin.transportOrigin) ?? .unknown)
        let control: CompactControl
        let target: String
        switch message {
        case let .buttonLight(button, _):
            control = .button(button)
            target = request.control_id
        case let .ringDisplay(encoder, _):
            control = .encoder(encoder)
            target = request.control_id
        case let .ringStyle(encoder, _):
            control = .encoder(encoder)
            target = request.control_id + ".style"
        }
        plan = try .init(reference: index, payload: message, origin: actor, scope: origin, source: .hardware,
                         endpointEvidence: endpoint, capturedEvidence: evidence, targetID: target,
                         affectedElements: [CompactNeutralProjection.elementID(control)], classification: .display, sideEffects: [], deliveryMode: .direct)
    }

    var message: HardwareDisplayMessage {
        plan.payload
    }

    /// Call at the existing native pin. Current identity and native route validity are both required.
    func requirePin(current: HardwareEndpointOrigin, isUsable: Bool) throws {
        let proof = FeedbackProof(plan: plan, nativeSnapshot: current, authorization: .granted(directions: [.display]),
                                  safety: isUsable ? .passed : .rejected(reason: "native_pin_unusable"))
        guard FeedbackPreflight.evaluate(plan: plan, proof: proof, currentScope: current, currentNativeSnapshot: current) == .permitted else {
            throw ControlContractError("invalid_transition")
        }
    }
}
