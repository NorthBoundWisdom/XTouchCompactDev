import Foundation
import RemoteToolContracts
import SurfaceControlContracts
import SurfaceDeviceContracts
import SurfaceFeedbackPlanning
import SurfacePluginContracts

/// Isolated software surface. This composition has no MIDI transport, user store,
/// system clock or business workflow. The existing session and device model own all
/// interactions; the shared contract owns validation and the public event cursor.
public struct CompactSurfaceSimulator: Sendable {
    public private(set) var session: CompactSession
    public private(set) var mock: MockXTouchCompact
    public private(set) var controls: SurfaceControlSession
    private let configuration: SurfaceConfiguration
    private let remoteWriterID: String
    private let systemWriterID: String
    private let writeLimits: ControlWriteLimits?
    /// Fader display overlays that no longer drive a motor. A fader overlay is a one-shot
    /// motor intent: an accepted position input on that fader or any layer selection
    /// supersedes it until a new feedback request for the same control re-arms it.
    private var releasedMotorOverlays: Set<String> = []

    #if DEBUG
        package mutating func installFeedbackShadow(_ audit: (any CompactFeedbackAudit)?, scheduler: (any CompactFeedbackSchedulerReference)?) {
            session.installFeedbackAudit(audit, scheduler: scheduler)
        }
    #endif

    public static let profileID = "xtouch.compact.standard.simulation"
    public static let profileVersion = "1.3"
    /// Physical A/B layer keys. They are layer-independent public buttons.
    public static let layerKeyIDs: [CompactLayer: String] = [.a: "global.layer.a", .b: "global.layer.b"]
    static let layeredKinds: [(kind: String, count: Int)] = [("fader", 9), ("touch", 9), ("encoder", 16), ("push", 16), ("button", 39),
                                                             ("expression", 1), ("footswitch", 1)]
    /// Fader touch is the momentary simulated hand on a motor fader. A lost client must not
    /// leave a fader touched (motor withheld) forever, so touch controls declare a contract 1.1
    /// lease that returns to released. Buttons bound to parameters toggle on press, so a lease
    /// on them would not restore anything and is deliberately not declared.
    public static let touchHold = ControlHold(restValue: .bool(false), maxHoldSeconds: 10)
    /// Contract 1.3 registered capabilities plus the XTouch-private touch protection rule.
    public static let capabilities = ["simulation", "controls.stable_ids", "controls.layered", "input.absolute", "input.button",
                                      "input.hold", "feedback.value", "feedback.indicator", "feedback.unsequenced", "controls.input_declared", "x.xtouch.touch_protection", "input.independent_sequence", "events.writer_id"]
    public static var demonstrationConfiguration: SurfaceConfiguration {
        let roles = ["arm", "start", "pause", "cancel"]
        var parameters = roles.map { ParameterDefinition(id: "simulation.\($0)", name: $0) }
        parameters += [ParameterDefinition(id: "simulation.state", name: "State", isSwitch: true),
                       ParameterDefinition(id: "simulation.progress", name: "Progress"),
                       ParameterDefinition(id: "simulation.link", name: "Link", isSwitch: true)]
        var assignments = roles.enumerated().map { ControlAssignment(control: .encoder($0.offset + 1), layer: .a, action: .parameter("simulation.\($0.element)")) }
        assignments += [.init(control: .button(1), layer: .a, action: .parameter("simulation.state")),
                        .init(control: .encoder(5), layer: .a, action: .parameter("simulation.progress")),
                        .init(control: .button(2), layer: .a, action: .parameter("simulation.link"))]
        return SurfaceConfiguration(parameters: parameters, assignments: assignments)
    }

    /// The mapping revision is derived from the profile (contract 1.1); it is never chosen by the host.
    public init(instanceID: String, epoch: String, configuration: SurfaceConfiguration = Self.demonstrationConfiguration, eventCapacity: Int = 1024,
                remoteWriterID: String = "simulation.remote", systemWriterID: String = "simulation.system", writeLimits: ControlWriteLimits? = nil, inputEventCapacity: Int? = nil) throws
    {
        try self.init(instanceID: instanceID, epoch: epoch, configuration: configuration, eventCapacity: eventCapacity,
                      remoteWriterID: remoteWriterID, systemWriterID: systemWriterID, writeLimits: writeLimits, inputEventCapacity: inputEventCapacity, contextReferences: nil)
    }

    package init(instanceID: String, epoch: String, configuration: SurfaceConfiguration = Self.demonstrationConfiguration, eventCapacity: Int = 1024,
                 remoteWriterID: String = "simulation.remote", systemWriterID: String = "simulation.system", writeLimits: ControlWriteLimits? = nil, inputEventCapacity: Int? = nil, contextReferences: CompactContextReferences?, feedbackAudit: (any CompactFeedbackAudit)? = nil, feedbackSchedulerReference: (any CompactFeedbackSchedulerReference)? = nil) throws
    {
        self.configuration = configuration
        self.remoteWriterID = remoteWriterID
        self.systemWriterID = systemWriterID
        self.writeLimits = writeLimits
        let map = try FactoryStandardMap()
        #if DEBUG
            session = CompactSession(map: map, lightProtocol: .manual, indicatorBindings: [:], feedbackAudit: feedbackAudit, feedbackSchedulerReference: feedbackSchedulerReference)
        #else
            session = CompactSession(map: map, lightProtocol: .manual, indicatorBindings: [:])
        #endif
        #if DEBUG
            if let contextReferences {
                session.installContextReferences(contextReferences)
            }
        #endif
        mock = MockXTouchCompact(map: map, lightProtocol: .manual)
        _ = try session.loadConfiguration(configuration, resetValues: true)
        let initialFeedback = try session.connect()
        controls = try SurfaceControlSession(instanceID: instanceID, epoch: epoch,
                                             profile: Self.profile(configuration: configuration, writeLimits: writeLimits, inputEventCapacity: inputEventCapacity), eventCapacity: eventCapacity, writeLimits: writeLimits, inputEventCapacity: inputEventCapacity)
        var initialScope = session.state.feedbackScope; initialScope.authorization = session.writeAuthorization
        var constructorEvidence = CompactFeedbackBytes(); constructorEvidence.add(instanceID); constructorEvidence.add(epoch)
        constructorEvidence.add(remoteWriterID); constructorEvidence.add(systemWriterID); constructorEvidence.add("permanent-simulation-constructor")
        let initialEndpoint = try EndpointProvenance(endpointID: instanceID, deviceID: nil, connectionGeneration: 0, transportOrigin: .localVirtual)
        let initialMap = session.state.map
        let initialPlans = try initialFeedback.enumerated().map { index, message in
            var reference = CompactFeedbackBytes(); reference.add(index)
            var origin = CompactFeedbackBytes(); origin.add(systemWriterID)
            return try CompactFeedbackPlanning.plan(message, map: initialMap, scope: initialScope, reference: reference,
                                                    origin: origin, source: .simulation, endpoint: initialEndpoint, evidence: constructorEvidence)
        }
        let initialPermitted = Self.permittedMockFeedback(initialFeedback, plans: initialPlans, scope: initialScope, state: session.state)
        mock.receive(initialPermitted.map(\.payload))
        #if DEBUG
            for plan in initialPlans {
                let accepted = initialPermitted.contains(plan)
                CompactFeedbackShadow.receipt(plan: plan, result: accepted ? .accepted : .notAttempted(reason: "preflight_rejected"), currentScope: initialScope, nativeCurrent: true, attempted: accepted, accepted: accepted, audit: session.state.feedbackAudit)
            }
        #endif
        try controls.validateWriterID(remoteWriterID)
        try controls.validateWriterID(systemWriterID)
        guard remoteWriterID != systemWriterID else { throw ControlContractError("invalid_argument") }
        try controls.seedInputs(mockInputs(), at: 0)
    }

    public static func profile(configuration: SurfaceConfiguration, writeLimits: ControlWriteLimits? = nil, inputEventCapacity: Int? = nil) -> ControlProfile {
        var descriptors: [ControlDescriptor] = []
        for layer in CompactLayer.allCases {
            for (kind, count) in layeredKinds {
                for index in 1 ... count {
                    let control = compactControl(kind: kind, index: index)!
                    let absolute = kind == "fader" || kind == "encoder" || kind == "expression"
                    let assignment = configuration.assignments.first(where: { $0.layer == layer && $0.control == control })?.action
                    var mapping: ControlMapping?
                    if case let .parameter(id) = assignment {
                        mapping = ControlMapping(kind: .parameter, id: id)
                    }
                    // Pedals have no RX feedback address: input only.
                    let feedback: [ControlFeedbackKind] = kind == "fader" || kind == "encoder" ? [.value] : (kind == "button" ? [.indicator] : [])
                    descriptors.append(.init(id: "\(layer.rawValue).\(kind).\(index)", inputKind: absolute ? .absolute : .button,
                                             encoding: absolute ? .scalar : .boolean,
                                             range: absolute ? .init(minimum: 0, maximum: 127, step: 1) : nil,
                                             feedbackKinds: feedback, mapping: mapping, hold: kind == "touch" && acceptsInput(assignment, configuration: configuration) ? touchHold : nil,
                                             acceptsInput: acceptsInput(assignment, configuration: configuration)))
                }
            }
        }
        for layer in CompactLayer.allCases {
            descriptors.append(.init(id: layerKeyIDs[layer]!, inputKind: .button, encoding: .boolean, acceptsInput: true))
        }
        // Public programmatic configurations may block every touch control. Advertise hold
        // only when a real eligible descriptor supports it; retain the default capability order.
        let declaredCapabilities = descriptors.contains { $0.hold != nil } ? capabilities : capabilities.filter { $0 != "input.hold" }
        return .init(id: profileID, version: inputEventCapacity == nil ? profileVersion : "1.5", controls: descriptors,
                     capabilities: declaredCapabilities + (writeLimits == nil ? [] : ["writes.independent_limits"]) + (inputEventCapacity == nil ? [] : ["events.input_retention"]))
    }

    /// Input eligibility is static mapping content. The shared session rejects `false` before
    /// this host considers the active layer; eligible inactive controls are still ignored.
    private static func acceptsInput(_ assignment: ParameterAction?, configuration: SurfaceConfiguration) -> Bool {
        guard let assignment else { return true }
        guard case let .parameter(id) = assignment,
              let definition = configuration.parameters.first(where: { $0.id == id }) else { return false }
        return definition.agentWritable && definition.externallyProtected != true
    }

    @discardableResult public mutating func input(_ input: ControlInput, at time: Double, writerID: String? = nil) throws -> ControlEvent {
        let writer = writerID ?? remoteWriterID
        _ = try controls.validateInput(input, at: time, writerID: writer)
        var next = self
        var disposition: ControlDisposition = .accepted
        var reason: String?
        var mapped: JSONValue?
        let unchanged = controls.isUnchanged(input)
        // Same raw value with only a lease change (hold_s added or renewed by a new input): the
        // contract session records the lease; the device gesture is not repeated.
        let sameRaw = try controls.snapshot(at: time).inputs[input.control_id] == SurfaceControlSession.normalized(input.value)
        if let target = Self.layerKey(input.control_id) {
            // A physical layer key is an ordinary input: identity, epoch and mapping are kept.
            if unchanged {
                disposition = .ignored; reason = "no_change"
            } else if input.value == .bool(true) {
                try next.switchLayer(target, at: time)
                mapped = .string(target.rawValue)
            }
        } else {
            let (layer, kind, index) = try Self.address(input.control_id)
            if layer == session.state.layer {
                try validateExternalWrite(kind: kind, index: index, layer: layer)
            }
            if layer != session.state.layer {
                disposition = .ignored; reason = "inactive_layer"
            } else if unchanged {
                disposition = .ignored; reason = "no_change"
            } else if sameRaw {
                mapped = next.mappedValue(kind: kind, index: index, layer: layer)
            } else {
                let messages: [MIDIMessage]
                switch kind {
                case "fader": messages = try next.mock.moveFader(index, value: UInt8(input.value.finiteNumber!))
                case "encoder": messages = try next.mock.turnEncoder(index, value: UInt8(input.value.finiteNumber!))
                case "touch": messages = try next.mock.touchFader(index, isTouched: input.value == .bool(true))
                case "push": messages = try next.mock.pushEncoder(index, isDown: input.value == .bool(true))
                case "button": messages = try next.mock.pressButton(index, isDown: input.value == .bool(true))
                case "expression": messages = try next.mock.moveExpression(UInt8(input.value.finiteNumber!))
                case "footswitch": messages = next.mock.pressFootswitch(isDown: input.value == .bool(true))
                default: throw ControlContractError("unsupported_control")
                }
                let update = try next.session.receive(messages)
                // Only parameter mappings are exposed by this software composition.
                // New action bindings require an explicit host composition, not a bypass.
                guard update.actionIntents.isEmpty else { throw ControlContractError("unsupported_mapping") }
                next.receiveMockFeedback(update.feedback, at: time, writerID: writer, operation: "input")
                if kind == "touch" {
                    try next.applyMomentaryTouch(index: index, layer: layer, pressed: input.value == .bool(true))
                }
                // The hand-placed fader supersedes its own display overlay; it is never pulled back.
                if kind == "fader" {
                    next.releasedMotorOverlays.insert(input.control_id)
                }
                try next.reassertDisplay(at: time)
                mapped = next.mappedValue(kind: kind, index: index, layer: layer)
            }
        }
        let event = try next.controls.recordInput(input, disposition: disposition, mappedValue: mapped, reason: reason, origin: .remote, at: time, writerID: writer)
        self = next
        return event
    }

    /// Standalone simulation only: a parameter-bound touch is momentary, unlike hardware
    /// parameter buttons, which retain their existing toggle semantics. Use the original
    /// layer on expiry; the active layer may have changed since the lease was acquired.
    private mutating func applyMomentaryTouch(index: Int, layer: CompactLayer, pressed: Bool) throws {
        try validateExternalWrite(kind: "touch", index: index, layer: layer)
        guard case let .parameter(id) = session.parameters.assignment(.faderTouch(index), layer: layer),
              let definition = session.parameters.definition(id) else { return }
        let feedback = try session.setParameter(id, value: pressed ? definition.maximum : definition.minimum, fromAgent: true)
        receiveMockFeedback(feedback, operation: "momentary-touch")
    }

    private func mappedValue(kind: String, index: Int, layer: CompactLayer) -> JSONValue? {
        guard case let .parameter(id) = session.parameters.assignment(Self.compactControl(kind: kind, index: index)!, layer: layer),
              let value = session.parameters.values[id] else { return nil }
        return .double(value)
    }

    /// Earliest unprocessed lease deadline, for the host scheduler.
    public var nextHoldDeadline: Double? {
        controls.nextHoldDeadline
    }

    /// Contract 1.1 silent renewal. No sequence, no event, no engine change.
    public mutating func renew(_ request: ControlRenew, at time: Double) throws -> ControlRenewResult {
        var next = controls
        let result = try next.renew(request, at: time)
        controls = next
        return result
    }

    /// Process every lease due at `time`, as the host scheduler: apply the rest value to the
    /// Mock and session through the same gesture as an input, then record `hold_expired`.
    /// Display overlays are reasserted once every due lease is recorded (a pending lease
    /// blocks contract reads). All or nothing: on failure nothing is committed.
    @discardableResult public mutating func processHoldExpiries(at time: Double) throws -> [ControlEvent] {
        let due = controls.dueHoldExpiries(at: time)
        guard !due.isEmpty else { return [] }
        // Validate every required global/input increment and trusted system identity before
        // touching the host engine. This copy is discarded; actual records carry mapped values.
        var validated = controls
        for expiry in due {
            _ = try validated.recordHoldExpiry(controlID: expiry.controlID, at: time, writerID: systemWriterID)
        }
        var next = self
        var events: [ControlEvent] = []
        for expiry in due {
            let (layer, kind, index) = try Self.address(expiry.controlID)
            guard kind == "touch", expiry.restValue == .bool(false) else { throw ControlContractError("invalid_transition") }
            // A touch lease always returns the physical sensor to released, on whichever
            // layer is active now: the touch state is per fader, not per layer.
            let messages = try next.mock.touchFader(index, isTouched: false)
            let update = try next.session.receive(messages)
            guard update.actionIntents.isEmpty else { throw ControlContractError("unsupported_mapping") }
            next.receiveMockFeedback(update.feedback, at: time, writerID: systemWriterID, operation: "hold-expiry")
            try next.applyMomentaryTouch(index: index, layer: layer, pressed: false)
            try events.append(next.controls.recordHoldExpiry(controlID: expiry.controlID,
                                                             mappedValue: next.mappedValue(kind: kind, index: index, layer: layer), at: time, writerID: systemWriterID))
        }
        try next.reassertDisplay(at: time)
        self = next
        return events
    }

    /// Mock and session switch together, as after a physical A/B key press. No motor is
    /// recalled: the session discards motor intents and fader overlays are superseded.
    /// Ring and indicator overlays of the newly active layer are redrawn.
    private mutating func switchLayer(_ layer: CompactLayer, at time: Double) throws {
        guard layer != session.state.layer else { return }
        mock.selectPhysicalLayer(layer)
        try receiveMockFeedback(session.selectLayer(layer), at: time, writerID: systemWriterID, operation: "layer")
        for id in try (controls.snapshot(at: time)).feedback.keys where Self.isFader(id) {
            releasedMotorOverlays.insert(id)
        }
        try reassertDisplay(at: time)
    }

    /// Business display state survives engine redraws without emitting events.
    private mutating func reassertDisplay(at time: Double) throws {
        for (id, channels) in try (controls.snapshot(at: time)).feedback where !releasedMotorOverlays.contains(id) {
            for (channel, value) in channels {
                try applyDisplay(.init(expected: controls.expected, expectedSequence: controls.discovery().latest_sequence, controlID: id, kind: channel, value: value))
            }
        }
    }

    private func validateExternalWrite(kind: String, index: Int, layer: CompactLayer) throws {
        guard let action = session.parameters.assignment(Self.compactControl(kind: kind, index: index)!, layer: layer) else { return }
        let ids: [String]
        switch action {
        case let .parameter(id): ids = [id]
        case .step, .set, .cycle, .resetGroup, .agent, .runMacro: throw ControlContractError("unsupported_mapping")
        }
        guard ids.allSatisfy({ id in session.parameters.definition(id).map { $0.agentWritable && $0.externallyProtected != true } ?? false }) else {
            throw ControlContractError("permission_denied")
        }
    }

    @discardableResult public mutating func feedback(_ feedback: ControlFeedback, at time: Double, writerID: String? = nil) throws -> ControlEvent {
        let writer = writerID ?? remoteWriterID
        _ = try controls.validateFeedback(feedback, at: time, writerID: writer)
        var next = self
        let (layer, _, _) = try Self.address(feedback.control_id)
        let active = layer == next.session.state.layer
        if active {
            next.releasedMotorOverlays.remove(feedback.control_id)
            try next.applyDisplay(feedback, at: time, writerID: writer)
        }
        let event = try next.controls.recordFeedback(feedback, disposition: active ? .accepted : .ignored,
                                                     reason: active ? nil : "inactive_layer", origin: .remote, at: time, writerID: writer)
        self = next
        return event
    }

    private mutating func applyDisplay(_ feedback: ControlFeedback, at: Double? = nil, writerID: String? = nil) throws {
        let (layer, kind, index) = try Self.address(feedback.control_id)
        guard layer == session.state.layer else { return }
        let messages: [MIDIMessage]
        switch kind {
        case "encoder": messages = try session.setDisplayRing(index, value: UInt8(feedback.value.finiteNumber!))
        case "fader": messages = try session.setDisplayFader(index, value: UInt8(feedback.value.finiteNumber!))
        case "button":
            let light: ButtonLight = feedback.value == .string("on") ? .on : (feedback.value == .string("blink") ? .blink : .off)
            messages = try session.setDisplayButton(index, light: light)
        default: throw ControlContractError("unsupported_feedback")
        }
        receiveMockFeedback(messages, at: at, writerID: writerID, operation: "display", request: String(reflecting: feedback))
    }

    /// Permanent software composition only. Virtual layer commands retain their
    /// original 1.3 behavior and do not acquire a hardware/local-attendance policy.
    private mutating func receiveMockFeedback(_ messages: [MIDIMessage], at: Double? = nil, writerID: String? = nil,
                                              operation: String, request: String? = nil)
    {
        var scope = session.state.feedbackScope; scope.authorization = session.writeAuthorization
        var evidence = CompactFeedbackBytes(); evidence.add(String(reflecting: controls.expected)); evidence.add(operation); evidence.add(request)
        evidence.add(at != nil); if let at {
            evidence.add(at)
        }; evidence.add(writerID)
        let endpoint = try! EndpointProvenance(endpointID: controls.expected.instance_id, deviceID: nil, connectionGeneration: 0, transportOrigin: .localVirtual)
        let plans = messages.enumerated().map { index, message in
            var reference = CompactFeedbackBytes(); reference.add(index); reference.add(operation)
            var origin = CompactFeedbackBytes(); origin.add(writerID)
            let planned: CompactPlannedProvenance? = if case let .controlChange(_, number, _) = message, (1 ... 9).contains(number) {
                session.state.producedMotorProvenance(Int(number))
            } else {
                nil
            }
            return try! CompactFeedbackPlanning.plan(message, map: session.state.map, scope: scope, reference: reference,
                                                     origin: origin, source: .simulation, endpoint: endpoint, evidence: evidence, planned: planned)
        }
        #if DEBUG
            var dispatchActor = CompactFeedbackBytes(); dispatchActor.add(writerID)
            var dispatchEvidence = evidence; dispatchEvidence.add(scope)
            session.feedbackShadowDispatch(.init(scope: scope, source: .simulation, origin: dispatchActor, endpointEvidence: endpoint,
                                                 dispatchEvidence: dispatchEvidence, currentScope: scope, nativeSnapshot: session.state.feedbackNativeSnapshot,
                                                 hardwareMotorActionCurrent: false, testAllowed: false, authorizedTestRequested: false, managementIntent: true))
        #endif
        let permitted = Self.permittedMockFeedback(messages, plans: plans, scope: scope, state: session.state)
        mock.receive(permitted.map(\.payload))
        #if DEBUG
            for plan in plans {
                let accepted = permitted.contains(plan)
                let result: FeedbackAttemptResult = accepted ? .accepted : .notAttempted(reason: "preflight_rejected")
                CompactFeedbackShadow.receipt(plan: plan, result: result, currentScope: scope, nativeCurrent: true, attempted: accepted, accepted: accepted, audit: session.state.feedbackAudit)
                session.feedbackShadowReceipt(plan, result: result, currentScope: scope, currentSource: .simulation, currentEndpoint: endpoint)
            }
        #endif
    }

    private static func permittedMockFeedback(_ messages: [MIDIMessage], plans: [CompactFeedbackPlan],
                                              scope: CompactFeedbackScope, state: CompactState) -> [CompactFeedbackPlan]
    {
        let facts = state.feedbackNativeSnapshot
        return zip(messages, plans).compactMap { message, plan in
            // Existing simulation operations have already produced this isolated Mock output.
            let proof = CompactFeedbackPlanning.nativeOutputProof(plan: plan, message: message, receiveChannel: state.map.globalReceiveChannel,
                                                                  permittedDirections: [.display, .mechanism, .management], nativeSnapshot: facts, safety: .passed)
            #if DEBUG
                CompactFeedbackShadow.preflight(plan: plan, proof: proof, currentScope: scope, currentNative: facts, native: .permitted, audit: state.feedbackAudit)
            #endif
            return FeedbackPreflight.evaluate(plan: plan, proof: proof, currentScope: scope, currentNativeSnapshot: facts) == .permitted ? plan : nil
        }
    }

    /// Rotation is a host lifecycle operation. Fresh epochs must come from host
    /// entropy; a remote reset can never choose or reuse a generation.
    public mutating func reset(expected: ControlExpected, expectedSequence: String, epoch: String, at time: Double) throws {
        var nextControls = controls
        try nextControls.reset(expected: expected, expectedSequence: expectedSequence, epoch: epoch, at: time)
        #if DEBUG
            var references: CompactContextReferences?
            if var resources = session.state.contextReference, var bindings = session.parameters.bindingReference {
                // A restart is a new value owner. Reset copied test references from constructor input,
                // never seed them from the new Kit result or share their mutable state.
                resources.reset()
                bindings.replace(configuration: .neutral)
                references = .init(resources: resources, bindings: bindings)
            }
        #else
            let references: CompactContextReferences? = nil
        #endif
        var next = try Self(instanceID: expected.instance_id, epoch: epoch,
                            configuration: configuration, eventCapacity: controls.eventCapacity,
                            remoteWriterID: remoteWriterID, systemWriterID: systemWriterID, writeLimits: writeLimits, inputEventCapacity: controls.inputEventCapacity, contextReferences: references)
        try nextControls.seedInputs(next.mockInputs(), at: time)
        next.controls = nextControls
        self = next
    }

    public mutating func reset(epoch: String, at time: Double) throws {
        try reset(expected: controls.expected, expectedSequence: controls.discovery().latest_sequence, epoch: epoch, at: time)
    }

    public mutating func selectLayer(_ layer: CompactLayer, epoch: String, at time: Double) throws {
        guard epoch != controls.expected.epoch else { throw ControlContractError("invalid_argument") }
        var next = self
        try next.receiveMockFeedback(next.session.selectLayer(layer), at: time, writerID: systemWriterID, operation: "reset-layer")
        next.releasedMotorOverlays.removeAll() // The epoch rotation clears all display intent.
        let expected = controls.discovery().expected
        try next.controls.reset(expected: expected, expectedSequence: controls.discovery().latest_sequence,
                                epoch: epoch, at: time)
        try next.controls.seedInputs(next.mockInputs(), at: time)
        self = next
    }

    private func mockInputs() -> [String: JSONValue] {
        var values: [String: JSONValue] = [:]
        for layer in CompactLayer.allCases {
            for index in 1 ... 9 {
                values["\(layer.rawValue).fader.\(index)"] = .number(Int(mock.faders[index - 1]))
                values["\(layer.rawValue).touch.\(index)"] = .bool(mock.touchedFaders.contains(index))
            }
            for index in 1 ... 16 {
                values["\(layer.rawValue).encoder.\(index)"] = .number(Int(mock.encoders[index - 1]))
                values["\(layer.rawValue).push.\(index)"] = .bool(mock.pushedEncoders.contains(index))
            }
            for index in 1 ... 39 {
                values["\(layer.rawValue).button.\(index)"] = .bool(mock.pressedButtons.contains(index))
            }
            // An expression pedal without a reading is unknown, not 0: omit it from the seed.
            if let expression = mock.expression {
                values["\(layer.rawValue).expression.1"] = .number(Int(expression))
            }
            values["\(layer.rawValue).footswitch.1"] = .bool(mock.footswitchDown)
        }
        for id in Self.layerKeyIDs.values {
            values[id] = .bool(false)
        }
        return values
    }

    private static func compactControl(kind: String, index: Int) -> CompactControl? {
        switch kind {
        case "fader": .fader(index); case "touch": .faderTouch(index); case "encoder": .encoder(index); case "push": .encoderPush(index); case "button": .button(index)
        case "expression" where index == 1: .expression
        case "footswitch" where index == 1: .footswitch
        default: nil
        }
    }

    private static func layerKey(_ id: String) -> CompactLayer? {
        layerKeyIDs.first { $0.value == id }?.key
    }

    private static func isFader(_ id: String) -> Bool {
        (try? address(id)).map { $0.1 == "fader" } ?? false
    }

    private static func address(_ id: String) throws -> (CompactLayer, String, Int) {
        let parts = id.split(separator: ".")
        guard parts.count == 3, let layer = CompactLayer(rawValue: String(parts[0])), let index = Int(parts[2]), compactControl(kind: String(parts[1]), index: index) != nil else { throw ControlContractError("unsupported_control") }
        return (layer, String(parts[1]), index)
    }
}
