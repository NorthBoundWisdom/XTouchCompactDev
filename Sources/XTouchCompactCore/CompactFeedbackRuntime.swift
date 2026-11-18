import Foundation
import SurfaceDeviceContracts
import SurfaceFeedbackPlanning

/// Length-delimited native facts. Text retains original UTF-8, not Swift's
/// canonically equivalent String equality. Optional tags and numeric bits survive.
package struct CompactFeedbackBytes: Equatable, Sendable, Codable {
    package private(set) var data = Data()
    package init() {}
    package mutating func add(_ value: UInt64) {
        var value = value.bigEndian
        withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }

    package mutating func add(_ value: Int) {
        add(UInt64(bitPattern: Int64(value)))
    }

    package mutating func add(_ value: Bool) {
        data.append(value ? 1 : 0)
    }

    package mutating func add(_ value: String) {
        let bytes = Data(value.utf8); add(UInt64(bytes.count)); data.append(bytes)
    }

    package mutating func add(_ value: String?) {
        add(value != nil); if let value {
            add(value)
        }
    }

    package mutating func add(_ value: CompactFeedbackBytes) {
        add(UInt64(value.data.count)); data.append(value.data)
    }

    package mutating func add(_ value: Double) {
        add(value.bitPattern)
    }

    package mutating func add(_ value: MIDIMessage) {
        add(UInt64(value.midi1Bytes.count)); data.append(contentsOf: value.midi1Bytes)
    }

    package mutating func add(_ value: EndpointProvenance) {
        add(value.endpointID); add(value.deviceID); add(value.connectionGeneration); add(value.transportOrigin.rawValue)
    }

    package mutating func add(_ value: DeviceContext) {
        add(value.id); add(value.generation); add(value.mappingRevision)
    }

    package mutating func add(_ value: CompactPlannedProvenance?) {
        add(value != nil)
        if let value {
            add(value.id); add(value.source.rawValue); add(value.endpoint); add(value.context); add(value.origin.rawValue); add(value.at)
        }
    }
}

/// Only the native lifecycle predicate; full descriptor evidence is separate.
package struct CompactFeedbackScope: Equatable, Sendable {
    package var inputID: Int32?
    package var outputID: Int32?
    package var transportGeneration: UInt64 = 0
    package var connected = false
    package var authorization: ParameterWriteAuthorization?
    package var bindingGeneration: UInt64 = 0
    package var authorizationRouteGeneration: UInt64 = 0
    package var hostLayer = CompactLayer.a
    package var hardwareMode = false
    package var listenOnly = false
    package var observationMode = false
    package var agentMotorPermission: Bool?
    package var transmitChannel: UInt8 = 0
    package var receiveChannel: UInt8 = 0
    package var lightProtocol = ButtonLightProtocol.manual
    package var handoverInactive = true
    package var transportOrigin: String?
    package init() {}
}

package struct CompactFeedbackCapturedEvidence: Equatable, Sendable {
    package let dispatch: CompactFeedbackBytes
    package let planned: CompactFeedbackBytes
    package init(dispatch: CompactFeedbackBytes, planned: CompactFeedbackBytes) {
        self.dispatch = dispatch; self.planned = planned
    }
}

package typealias CompactFeedbackPlan = FeedbackPlan<MIDIMessage, CompactFeedbackBytes, CompactFeedbackScope, CompactFeedbackBytes, CompactFeedbackCapturedEvidence>
package typealias CompactFeedbackProof = FeedbackProof<CompactFeedbackPlan, CompactFeedbackBytes>

/// Caller operations before generation dedup. The test-owned scheduler reference
/// is a mutating value existential so candidate/session copies do not share state.
package enum CompactFeedbackIntent: Sendable {
    case request(key: String, message: MIDIMessage, provenance: CompactPlannedProvenance?)
    case style(key: String, message: MIDIMessage, projectionKey: String, provenance: CompactPlannedProvenance?)
    case release(key: String)
    case cancel(key: String)
    case clear
    case invalidate(keys: [String])
    case refresh(order: [String])
}

#if DEBUG
    package enum CompactGeneratedDisplayFamily: String, Sendable {
        case button, ring, style
    }

    package enum CompactGeneratedDisplayValue: Equatable, Sendable {
        case button(ButtonLight), ring(RingDisplay), style(RingStyle)

        package var family: CompactGeneratedDisplayFamily {
            switch self {
            case .button: .button
            case .ring: .ring
            case .style: .style
            }
        }
    }

    package enum CompactGeneratedDisplayInput: Sendable {
        case request(index: Int, value: CompactGeneratedDisplayValue, scope: CompactResourceScope,
                     map: FactoryStandardMap, lightProtocol: ButtonLightProtocol)
        case invalidate(family: CompactGeneratedDisplayFamily, index: Int?)

        package var family: CompactGeneratedDisplayFamily {
            switch self {
            case let .request(_, value, _, _, _): value.family
            case let .invalidate(family, _): family
            }
        }
    }

    package struct CompactGeneratedDisplaySnapshot: Equatable, Sendable {
        package let orderedIndices: [Int]
        package let values: [Int: CompactGeneratedDisplayValue]
        package let scopes: [Int: CompactResourceScope]

        package init(orderedIndices: [Int], values: [Int: CompactGeneratedDisplayValue], scopes: [Int: CompactResourceScope]) {
            self.orderedIndices = orderedIndices
            self.values = values
            self.scopes = scopes
        }
    }
#endif

package protocol CompactFeedbackSchedulerReference: Sendable {
    mutating func receive(_ intent: CompactFeedbackIntent, scope: CompactFeedbackScope, native: CompactState)
    mutating func generated(_ messages: [MIDIMessage], scope: CompactFeedbackScope, provenance: [CompactPlannedProvenance?])
    mutating func dispatch(_ facts: CompactFeedbackDispatchFacts, native: CompactState)
    mutating func receipt(_ plan: CompactFeedbackPlan, result: FeedbackAttemptResult, currentScope: CompactFeedbackScope, stateScope: CompactFeedbackScope, currentSource: DeviceSource, currentEndpoint: EndpointProvenance)
    mutating func reset()
    #if DEBUG
        var comparesGeneratedDisplay: Bool {
            get
        }
        mutating func compareGeneratedDisplay(_ input: CompactGeneratedDisplayInput, nativeProposal: MIDIMessage?, nativeState: CompactGeneratedDisplaySnapshot)
    #endif
}

#if DEBUG
    package extension CompactFeedbackSchedulerReference {
        var comparesGeneratedDisplay: Bool {
            false
        }

        mutating func compareGeneratedDisplay(_: CompactGeneratedDisplayInput, nativeProposal _: MIDIMessage?, nativeState _: CompactGeneratedDisplaySnapshot) {}
    }
#endif

package enum CompactFeedbackPlanning {
    /// The trusted command and the adapter's existing gates determine the grant.
    /// The plan declares the effects that must fit that grant.
    package static func nativeOutputProof(plan: CompactFeedbackPlan, message: MIDIMessage, receiveChannel: UInt8,
                                          permittedDirections: Set<EffectDirection>, nativeSnapshot: CompactFeedbackBytes,
                                          safety: NativeSafetyResult) -> CompactFeedbackProof
    {
        let nativeDirections: Set<EffectDirection> = switch message {
        case let .controlChange(channel, 1 ... 9, _) where channel == receiveChannel: [.mechanism]
        case let .controlChange(channel, 10 ... 41, _) where channel == receiveChannel: [.display]
        case let .noteOn(channel, 0 ... 38, _) where channel == receiveChannel: [.display]
        case let .programChange(channel, 0 ... 1) where channel == receiveChannel: [.management, .mechanism]
        default: []
        }
        return nativeOutputProof(plan: plan, message: message, nativeDirections: nativeDirections, permittedDirections: permittedDirections,
                                 nativeSnapshot: nativeSnapshot, safety: safety)
    }

    package static func nativeOutputProof(plan: CompactFeedbackPlan, message: MIDIMessage, nativeDirections: Set<EffectDirection>,
                                          permittedDirections: Set<EffectDirection>, nativeSnapshot: CompactFeedbackBytes,
                                          safety: NativeSafetyResult) -> CompactFeedbackProof
    {
        guard plan.payload == message else {
            return .init(plan: plan, nativeSnapshot: nativeSnapshot, authorization: .denied(reason: "native_output_payload_mismatch"), safety: safety)
        }
        let grant = nativeDirections.intersection(permittedDirections)
        let authorization: PlanAuthorization = grant.isEmpty ? .denied(reason: "native_output_authorization") : .granted(directions: grant)
        return .init(plan: plan, nativeSnapshot: nativeSnapshot, authorization: authorization, safety: safety)
    }

    package static func plan(_ message: MIDIMessage, map: FactoryStandardMap, scope: CompactFeedbackScope,
                             reference: CompactFeedbackBytes, origin: CompactFeedbackBytes, source: DeviceSource,
                             endpoint: EndpointProvenance, evidence: CompactFeedbackBytes, planned: CompactPlannedProvenance? = nil) throws -> CompactFeedbackPlan
    {
        let (target, affected, _, classification, effects) = try CompactNeutralProjection.feedbackShape(message, map: map, hostLayer: scope.hostLayer)
        var queued = CompactFeedbackBytes(); queued.add(planned)
        var fullEvidence = evidence; fullEvidence.add(scope)
        return try .init(reference: reference, payload: message, origin: origin, scope: scope, source: source,
                         endpointEvidence: endpoint, capturedEvidence: .init(dispatch: fullEvidence, planned: queued), targetID: target, affectedElements: affected,
                         classification: classification, sideEffects: effects, deliveryMode: .direct)
    }
}

/// Adapter facts only, never an allowed-output list. Candidate-specific native
/// validation still runs on an isolated CompactState value for each proposal.
package struct CompactFeedbackDiagnosticFacts: Sendable {
    package let gate: NonMotorTestGate
    package let authorization: AuthorizedNonMotorTest
    package let context: NonMotorTransportContext
    package init(gate: NonMotorTestGate, authorization: AuthorizedNonMotorTest, context: NonMotorTransportContext) {
        self.gate = gate; self.authorization = authorization; self.context = context
    }
}

package struct CompactFeedbackDispatchFacts: Sendable {
    package let scope: CompactFeedbackScope
    package let source: DeviceSource
    package let origin: CompactFeedbackBytes
    package let endpointEvidence: EndpointProvenance
    package let dispatchEvidence: CompactFeedbackBytes
    package let currentScope: CompactFeedbackScope
    package let nativeSnapshot: CompactFeedbackBytes
    package let hardwareMotorActionCurrent: Bool
    package let testAllowed: Bool
    package let authorizedTestRequested: Bool
    package let managementIntent: Bool
    package let diagnostic: CompactFeedbackDiagnosticFacts?
    package init(scope: CompactFeedbackScope, source: DeviceSource, origin: CompactFeedbackBytes, endpointEvidence: EndpointProvenance,
                 dispatchEvidence: CompactFeedbackBytes, currentScope: CompactFeedbackScope, nativeSnapshot: CompactFeedbackBytes,
                 hardwareMotorActionCurrent: Bool, testAllowed: Bool, authorizedTestRequested: Bool, managementIntent: Bool, diagnostic: CompactFeedbackDiagnosticFacts? = nil)
    {
        self.scope = scope; self.source = source; self.origin = origin; self.endpointEvidence = endpointEvidence; self.dispatchEvidence = dispatchEvidence
        self.currentScope = currentScope; self.nativeSnapshot = nativeSnapshot; self.hardwareMotorActionCurrent = hardwareMotorActionCurrent
        self.testAllowed = testAllowed; self.authorizedTestRequested = authorizedTestRequested; self.managementIntent = managementIntent; self.diagnostic = diagnostic
    }
}

package extension CompactFeedbackBytes {
    mutating func add(_ value: CompactFeedbackScope) {
        for id in [value.inputID, value.outputID] {
            add(id != nil); if let id {
                add(Int(id))
            }
        }
        add(value.transportGeneration); add(value.connected)
        add(value.bindingGeneration); add(value.authorizationRouteGeneration)
        add(value.authorization != nil)
        if let auth = value.authorization {
            add(auth.routeGeneration); add(auth.bindingGeneration)
            add(auth.allowedWriters != nil)
            if let writers = auth.allowedWriters {
                let raw = writers.map(\.rawValue).sorted(); add(raw.count); for item in raw {
                    add(item)
                }
            }
            add(auth.allowedParameters != nil)
            if let ids = auth.allowedParameters {
                let raw = ids.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }; add(raw.count); for item in raw {
                    add(item)
                }
            }
            add(auth.allowsValues); add(auth.allowsDisplay); add(auth.allowsMechanisms)
        }
        add(value.hostLayer.rawValue); add(value.hardwareMode); add(value.listenOnly); add(value.observationMode)
        add(value.agentMotorPermission != nil); if let permission = value.agentMotorPermission {
            add(permission)
        }
        add(Int(value.transmitChannel)); add(Int(value.receiveChannel)); add(value.lightProtocol.rawValue); add(value.handoverInactive); add(value.transportOrigin)
    }
}
