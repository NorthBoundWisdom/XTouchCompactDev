import Foundation
import SurfaceBindingContext

/// Host-owned state and feedback policy. Hardware commands are returned as messages;
/// the caller routes them through its CoreMIDI transport. No physical motor is used by tests.
public struct CompactState: Sendable {
    #if DEBUG
        package var feedbackSchedulerReference: (any CompactFeedbackSchedulerReference)?
        private var feedbackDerivedDepth = 0
        private var feedbackCallerProvenance: CompactPlannedProvenance?
    #endif
    private var resourceScope = CompactResourceScope()
    private var pendingIndex = ContextResourceIndex<Int, CompactResourceScope>()
    private var buttonCacheIndex = ContextResourceIndex<Int, CompactResourceScope>()
    private var ringCacheIndex = ContextResourceIndex<Int, CompactResourceScope>()
    private var styleCacheIndex = ContextResourceIndex<Int, CompactResourceScope>()
    public let map: FactoryStandardMap
    public let lightProtocol: ButtonLightProtocol
    public private(set) var layer: CompactLayer = .a

    public private(set) var observedLayer: CompactLayer?
    /// Revision of actual decoded input, independent from requests and delivery receipts.
    public private(set) var observationRevision: UInt64 = 0
    private var layerObservationRevision: UInt64 = 0
    private var faderObservationRevisions: [Int: UInt64] = [:]
    public var layerMismatch: Bool {
        observedLayer.map { $0 != layer } ?? false
    }

    private var safetyTouches: Set<Int> = []
    private var touchedFaders: Set<Int> = []
    private var desiredFader: [Int: UInt8] = [:]
    private var observedFaders: [Int: UInt8] = [:]
    private var lastMotorCommands: [Int: UInt8] = [:]
    // A position report becomes stale as soon as the host commands a motor movement.
    private var observedIsCurrent: Set<Int> = []
    private var pendingProvenance: [Int: CompactPlannedProvenance] = [:]
    private var producedProvenance: [Int: CompactPlannedProvenance] = [:]
    private var desiredButtons: [Int: ButtonLight] = [:]
    private var lastSentButtons: [Int: ButtonLight] = [:]
    private var desiredRings: [Int: RingDisplay] = [:]
    private var lastSentRings: [Int: RingDisplay] = [:]
    private var desiredStyles: [Int: RingStyle] = [:]
    private var lastSentStyles: [Int: RingStyle] = [:]
    private var pressedButtons: Set<Int> = []
    private var pushedEncoders: Set<Int> = []

    package var feedbackScope: CompactFeedbackScope {
        var scope = CompactFeedbackScope()
        scope.hostLayer = layer; scope.transmitChannel = map.transmitChannel
        scope.receiveChannel = map.globalReceiveChannel; scope.lightProtocol = lightProtocol
        scope.bindingGeneration = resourceScope.bindingGeneration
        scope.authorizationRouteGeneration = resourceScope.authorizationRouteGeneration
        return scope
    }

    /// A transient complete gate snapshot, never another value owner or observation.
    package var feedbackNativeSnapshot: CompactFeedbackBytes {
        var facts = CompactFeedbackBytes()
        facts.add(layer.rawValue); facts.add(observedLayer?.rawValue)
        facts.add(observationRevision); facts.add(layerObservationRevision)
        for index in 1 ... 9 {
            facts.add(index); facts.add(touchedFaders.contains(index)); facts.add(safetyTouches.contains(index))
            for value in [desiredFader[index], observedFaders[index], lastMotorCommands[index]] {
                facts.add(value != nil); if let value {
                    facts.add(Int(value))
                }
            }
            facts.add(observedIsCurrent.contains(index)); facts.add(faderObservationRevisions[index, default: 0])
            facts.add(pendingProvenance[index]); facts.add(producedProvenance[index])
        }
        return facts
    }

    #if DEBUG
        private mutating func feedbackIntent(_ intent: CompactFeedbackIntent) {
            guard feedbackDerivedDepth == 0, feedbackSchedulerReference != nil else { return }
            // Copy first; a mutating value existential must not observe itself via an inout alias.
            var snapshot = self; snapshot.feedbackSchedulerReference = nil
            let scope = feedbackScope
            feedbackSchedulerReference?.receive(intent, scope: scope, native: snapshot)
        }

        private func feedbackProducedProvenance(_ messages: [MIDIMessage]) -> [CompactPlannedProvenance?] {
            messages.map { message in
                if case let .controlChange(_, number, _) = message, (1 ... 9).contains(number) {
                    return producedProvenance[Int(number)]
                }
                return feedbackCallerProvenance
            }
        }

        private mutating func feedbackGenerated(_ messages: [MIDIMessage]) {
            guard feedbackDerivedDepth == 0, feedbackSchedulerReference != nil else { return }
            let scope = feedbackScope
            let provenance = feedbackProducedProvenance(messages)
            feedbackSchedulerReference?.generated(messages, scope: scope, provenance: provenance)
        }
    #endif

    /// Planning provenance is transient caller input; stored index entries capture its value.
    mutating func setResourceProvenance(_ provenance: CompactPlannedProvenance?) {
        #if DEBUG
            feedbackCallerProvenance = provenance
        #endif
        resourceScope.source = provenance?.source
        resourceScope.endpoint = provenance?.endpoint
    }

    /// Authorization epochs are real caller facts, separate from physical observations.
    mutating func setResourceAuthorization(_ authorization: ParameterWriteAuthorization) {
        resourceScope.bindingGeneration = authorization.bindingGeneration
        resourceScope.authorizationRouteGeneration = authorization.routeGeneration
    }

    private func pendingContains(_ index: Int) -> Bool {
        pendingIndex.contains(index)
    }

    private func sortedPending() -> [Int] {
        pendingIndex.orderedIDs.sorted()
    }

    private mutating func insertPending(_ index: Int, provenance: CompactPlannedProvenance? = nil) {
        var scope = resourceScope
        if let provenance {
            scope.source = provenance.source; scope.endpoint = provenance.endpoint
        }
        pendingIndex.upsert(index, scope: scope)
    }

    private mutating func removePending(_ index: Int) {
        _ = pendingIndex.remove(index)
    }

    private mutating func clearPending() {
        _ = pendingIndex.removeAll()
    }

    private func cachedButton(_ index: Int) -> ButtonLight? {
        buttonCacheIndex.contains(index) ? lastSentButtons[index] : nil
    }

    private mutating func storeButton(_ index: Int, _ value: ButtonLight) {
        lastSentButtons[index] = value
        buttonCacheIndex.upsert(index, scope: resourceScope)
    }

    private mutating func clearButtonCache(_ index: Int? = nil) {
        let removed: [Int] = if let index {
            buttonCacheIndex.remove(index) ? [index] : []
        } else {
            buttonCacheIndex.removeAll()
        }
        for id in removed {
            lastSentButtons.removeValue(forKey: id)
        }
    }

    private func cachedRing(_ index: Int) -> RingDisplay? {
        ringCacheIndex.contains(index) ? lastSentRings[index] : nil
    }

    private mutating func storeRing(_ index: Int, _ value: RingDisplay) {
        lastSentRings[index] = value
        ringCacheIndex.upsert(index, scope: resourceScope)
    }

    private mutating func clearRingCache(_ index: Int? = nil) {
        let removed: [Int] = if let index {
            ringCacheIndex.remove(index) ? [index] : []
        } else {
            ringCacheIndex.removeAll()
        }
        for id in removed {
            lastSentRings.removeValue(forKey: id)
        }
    }

    private func cachedStyle(_ index: Int) -> RingStyle? {
        styleCacheIndex.contains(index) ? lastSentStyles[index] : nil
    }

    private mutating func storeStyle(_ index: Int, _ value: RingStyle) {
        lastSentStyles[index] = value
        styleCacheIndex.upsert(index, scope: resourceScope)
    }

    private mutating func clearStyleCache(_ index: Int? = nil) {
        let removed: [Int] = if let index {
            styleCacheIndex.remove(index) ? [index] : []
        } else {
            styleCacheIndex.removeAll()
        }
        for id in removed {
            lastSentStyles.removeValue(forKey: id)
        }
    }

    public init(map: FactoryStandardMap, lightProtocol: ButtonLightProtocol) {
        self.map = map; self.lightProtocol = lightProtocol
        resourceScope.transmitChannel = map.transmitChannel
        resourceScope.receiveChannel = map.globalReceiveChannel
        resourceScope.lightProtocol = lightProtocol.rawValue
    }

    /// Last actual TX position report, possibly stale after a motor command. Sending RX
    /// feedback never updates this observation; no report means nil.
    public func observedFader(_ index: Int) -> UInt8? {
        observedFaders[index]
    }

    public func isTouched(_ index: Int) -> Bool {
        touchedFaders.contains(index) || safetyTouches.contains(index)
    }

    /// Layer assertions can drive all nine motors, so either touch source blocks them.
    public func validateLayerAssertion() throws {
        guard !(1 ... 9).contains(where: isTouched) else { throw CompactError.fadersTouched }
    }

    public func isMotorPending(_ index: Int) -> Bool {
        pendingContains(index)
    }

    /// Read-only native pending intent inventory, including the real desired payload.
    public var pendingMotorFacts: [CompactPendingMotorFact] {
        sortedPending().map { CompactPendingMotorFact(index: $0, target: desiredFader[$0], observed: observedFaders[$0], touched: isTouched($0), provenance: pendingProvenance[$0]) }
    }

    public func producedMotorProvenance(_ index: Int) -> CompactPlannedProvenance? {
        producedProvenance[index]
    }

    public func desiredButton(_ index: Int) -> ButtonLight? {
        desiredButtons[index]
    }

    public func desiredRing(_ index: Int) -> RingDisplay? {
        desiredRings[index]
    }

    public func desiredRingStyle(_ index: Int) -> RingStyle? {
        desiredStyles[index]
    }

    public func isButtonDown(_ index: Int) -> Bool {
        pressedButtons.contains(index)
    }

    public func isEncoderPushed(_ index: Int) -> Bool {
        pushedEncoders.contains(index)
    }

    /// Software simulation may assert the layer immediately. Physical attachments must
    /// use assertLayer: false: invalidate old observations/intents without output.
    /// Neither path clears touch or recalls bank targets.
    public mutating func connect(assertLayer: Bool = true) throws -> [MIDIMessage] {
        #if DEBUG
            if feedbackSchedulerReference != nil {
                feedbackIntent(.clear)
            }
        #endif
        lastMotorCommands.removeAll()
        observedIsCurrent.removeAll()
        observedFaders.removeAll()
        clearButtonCache()
        clearRingCache()
        clearStyleCache()
        clearPending(); pendingProvenance.removeAll(); producedProvenance.removeAll()
        pressedButtons.removeAll()
        pushedEncoders.removeAll()
        guard assertLayer else {
            observedLayer = nil
            desiredFader.removeAll()
            return []
        }
        var result = [map.selectLayer(layer)]
        result += try restoreNonMotorFeedback()
        return result
    }

    /// Change host intent without claiming that a layer command reached the device.
    /// Used during listening and before the transport accepts an explicit assertion.
    public mutating func selectHostLayer(_ layer: CompactLayer) {
        #if DEBUG
            if feedbackSchedulerReference != nil {
                feedbackIntent(.clear)
            }
        #endif
        clearPending(); pendingProvenance.removeAll(); producedProvenance.removeAll()
        desiredFader.removeAll()
        invalidateMotorCommandHistory()
        self.layer = layer
        resourceScope.hostLayer = layer
    }

    /// Delivery invalidates prior layer evidence; it never acknowledges a physical layer.
    public mutating func didTransmitLayerAssertion(preservingObservationsAfter cutoff: UInt64? = nil) {
        let newerCurrent = observedIsCurrent.filter { index in
            cutoff.map { faderObservationRevisions[index, default: 0] > $0 } ?? false
        }
        invalidateMotorCommandHistory()
        observedIsCurrent.formUnion(newerCurrent)
        if cutoff.map({ layerObservationRevision <= $0 }) ?? true {
            observedLayer = nil
        }
    }

    @discardableResult
    public mutating func selectLayer(_ layer: CompactLayer) -> MIDIMessage {
        selectHostLayer(layer)
        didTransmitLayerAssertion()
        // Deterministic simulation assumes the returned assertion is delivered.
        return map.selectLayer(layer)
    }

    /// Decode input and invalidate stale feedback cache where local hardware behavior may overwrite LEDs.
    /// The domain engine consumes the returned CompactInput and chooses the resulting parameter value.
    public mutating func receive(_ message: MIDIMessage) -> CompactInput? {
        guard let event = map.decode(message) else { return nil }
        observeDecodedInput(event)
        return event
    }

    /// A trusted adapter may retain an input's original decoding across a callback handover.
    /// This records physical facts only; it does not apply assignments or return feedback.
    public mutating func observeDecodedInput(_ event: CompactInput) {
        observationRevision &+= 1
        // A release ends a gesture; it cannot prove the device returned to our layer.
        // Once contradicted, withheld motion is obsolete even if fresh positive input
        // later restores layer agreement.
        if !layerMismatch || event.isPressed != false {
            observedLayer = event.layer
            layerObservationRevision = observationRevision
        }
        #if DEBUG
            switch event.control {
            case let .encoder(index): if feedbackSchedulerReference != nil {
                    feedbackIntent(.invalidate(keys: ["ring.\(index)"]))
                }
            case let .button(index):
                if event.isPressed == true, (34 ... 39).contains(index) {
                    if feedbackSchedulerReference != nil {
                        feedbackIntent(.invalidate(keys: (34 ... 39).map { "button.\($0)" }))
                    }
                } else if event.isPressed == false, feedbackSchedulerReference != nil {
                    feedbackIntent(.invalidate(keys: ["button.\(index)"]))
                }
            default: break
            }
        #endif
        if layerMismatch {
            #if DEBUG
                for index in 1 ... 9 {
                    if feedbackSchedulerReference != nil {
                        feedbackIntent(.cancel(key: "fader.\(index)"))
                    }
                }
            #endif
            clearPending(); pendingProvenance.removeAll(); producedProvenance.removeAll()
        }
        switch event.control {
        case let .fader(i):
            observedFaders[i] = event.value
            faderObservationRevisions[i] = observationRevision
            observedIsCurrent.insert(i)
        case let .faderTouch(i):
            if event.isPressed == true {
                touchedFaders.insert(i)
            } else {
                touchedFaders.remove(i)
            }
        case let .encoder(i): clearRingCache(i)
        case let .button(i):
            if event.isPressed == true {
                pressedButtons.insert(i)
            } else {
                pressedButtons.remove(i)
            }
            if event.isPressed == true, (34 ... 39).contains(i) {
                // The six right-area transport buttons may redraw *the whole group* locally.
                for index in 34 ... 39 {
                    clearButtonCache(index)
                }
            } else if event.isPressed == false {
                clearButtonCache(i)
            }
        case let .encoderPush(i):
            if event.isPressed == true {
                pushedEncoders.insert(i)
            } else {
                pushedEncoders.remove(i)
            }
        case .expression, .footswitch: break // No LED, ring or motor is associated with a pedal.
        }
    }

    /// Use only after a decoded fader-touch release; compare with the observed physical position.
    public mutating func reconcileReleasedFader(_ index: Int) throws -> [MIDIMessage] {
        guard (1 ... 9).contains(index) else { throw CompactError.invalidIndex("fader", index) }
        #if DEBUG
            if feedbackSchedulerReference != nil {
                feedbackIntent(.release(key: "fader.\(index)"))
            }
        #endif
        let messages = try reconcileReleasedFaderNative(index)
        #if DEBUG
            feedbackGenerated(messages)
        #endif
        return messages
    }

    private mutating func reconcileReleasedFaderNative(_ index: Int) throws -> [MIDIMessage] {
        guard (1 ... 9).contains(index) else { throw CompactError.invalidIndex("fader", index) }
        guard !isTouched(index), !layerMismatch, pendingContains(index),
              let desired = desiredFader[index] else { return [] }
        let originalProvenance = pendingProvenance[index]
        producedProvenance.removeValue(forKey: index)
        removePending(index); pendingProvenance.removeValue(forKey: index)
        if observedIsCurrent.contains(index), observedFaders[index] == desired {
            return []
        }
        if !observedIsCurrent.contains(index), lastMotorCommands[index] == desired {
            return []
        }
        lastMotorCommands[index] = desired
        observedIsCurrent.remove(index)
        let command = try map.motorPosition(fader: index, value: desired)
        producedProvenance[index] = originalProvenance
        return [command]
    }

    /// When touched, only update desired state; never drive the motor against the user's hand.
    public mutating func setFader(_ index: Int, value: UInt8, provenance: CompactPlannedProvenance? = nil) throws -> [MIDIMessage] {
        guard (1 ... 9).contains(index) else { throw CompactError.invalidIndex("fader", index) }
        #if DEBUG
            if feedbackSchedulerReference != nil {
                try feedbackIntent(.request(key: "fader.\(index)", message: map.motorPosition(fader: index, value: value), provenance: provenance))
            }
        #endif
        let messages = try _setFader(index, value: value, provenance: provenance)
        #if DEBUG
            feedbackGenerated(messages)
        #endif
        return messages
    }

    private mutating func _setFader(_ index: Int, value: UInt8, provenance: CompactPlannedProvenance? = nil) throws -> [MIDIMessage] {
        guard (1 ... 9).contains(index) else { throw CompactError.invalidIndex("fader", index) }
        producedProvenance.removeValue(forKey: index)
        desiredFader[index] = value
        if pendingContains(index) {
            // The same shared slot receives new immutable scope without moving its order.
            insertPending(index, provenance: provenance)
            pendingProvenance[index] = provenance
        }
        guard !layerMismatch else { removePending(index); pendingProvenance.removeValue(forKey: index); return [] }
        if isTouched(index) {
            insertPending(index, provenance: provenance)
            pendingProvenance[index] = provenance
            return []
        }
        if observedIsCurrent.contains(index) {
            guard observedFaders[index] != value else { return [] }
        } else {
            guard lastMotorCommands[index] != value else { return [] }
        }
        lastMotorCommands[index] = value
        observedIsCurrent.remove(index)
        let command = try map.motorPosition(fader: index, value: value)
        producedProvenance[index] = provenance
        return [command]
    }

    /// Recheck generated feedback against the latest state before delivery. Later inputs
    /// in a batch can revoke an earlier motor command or replace its authority entirely.
    public mutating func filterFeedbackForDelivery(_ messages: [MIDIMessage]) -> [MIDIMessage] {
        var permitted: [MIDIMessage] = []
        for message in messages {
            if case let .controlChange(_, number, value) = message, (1 ... 9).contains(number) {
                let index = Int(number)
                // A newer physical report or motor-less write may have discarded this intent.
                guard desiredFader[index] == value else { continue }
                if layerMismatch || isTouched(index) {
                    if lastMotorCommands[index] == value {
                        lastMotorCommands.removeValue(forKey: index)
                    }
                    if layerMismatch {
                        removePending(index); pendingProvenance.removeValue(forKey: index)
                    } else {
                        insertPending(index, provenance: producedProvenance[index])
                        pendingProvenance[index] = producedProvenance[index]
                    }
                    continue
                }
            }
            permitted.append(message)
        }
        return permitted
    }

    /// Safety ownership is independent of the currently selected transport (e.g. hardware while mocking).
    public mutating func setSafetyTouch(_ index: Int, touched: Bool) {
        guard (1 ... 9).contains(index) else { return }
        if touched {
            safetyTouches.insert(index)
        } else {
            safetyTouches.remove(index)
        }
    }

    public mutating func cancelMotorIntents() {
        discardPendingMotorWrites()
        observedFaders.removeAll(); observedLayer = nil
    }

    /// Discard withheld writes without inventing a layer assertion or losing physical evidence.
    public mutating func discardPendingMotorWrites() {
        #if DEBUG
            for index in 1 ... 9 {
                if feedbackSchedulerReference != nil {
                    feedbackIntent(.cancel(key: "fader.\(index)"))
                }
            }
        #endif
        clearPending(); pendingProvenance.removeAll(); producedProvenance.removeAll(); desiredFader.removeAll(); invalidateMotorCommandHistory()
    }

    public mutating func setInputTouches(_ touches: Set<Int>) {
        touchedFaders = touches
    }

    /// Forget a withheld motor intent without claiming a physical observation, so a later
    /// touch release cannot replay an older target over a newer, motor-less write.
    public mutating func discardMotorIntent(_ index: Int) {
        #if DEBUG
            if feedbackSchedulerReference != nil {
                feedbackIntent(.cancel(key: "fader.\(index)"))
            }
        #endif
        desiredFader.removeValue(forKey: index)
        removePending(index); pendingProvenance.removeValue(forKey: index)
        producedProvenance.removeValue(forKey: index)
    }

    /// A physical fader report owns its own position. Parameter snapping must never echo a motor command.
    public mutating func acceptPhysicalFader(_ index: Int) {
        #if DEBUG
            if feedbackSchedulerReference != nil {
                feedbackIntent(.cancel(key: "fader.\(index)"))
            }
        #endif
        desiredFader.removeValue(forKey: index)
        removePending(index); pendingProvenance.removeValue(forKey: index)
        producedProvenance.removeValue(forKey: index)
        lastMotorCommands.removeValue(forKey: index)
    }

    public mutating func setButton(_ index: Int, light: ButtonLight) throws -> [MIDIMessage] {
        guard (1 ... 39).contains(index) else { throw CompactError.invalidIndex("button", index) }
        #if DEBUG
            if feedbackSchedulerReference != nil {
                try feedbackIntent(.request(key: "button.\(index)", message: map.buttonLight(button: index, light: light, style: lightProtocol), provenance: feedbackCallerProvenance))
            }
        #endif
        let messages = try _setButton(index, light: light)
        #if DEBUG
            feedbackGenerated(messages)
        #endif
        return messages
    }

    private mutating func _setButton(_ index: Int, light: ButtonLight) throws -> [MIDIMessage] {
        guard (1 ... 39).contains(index) else { throw CompactError.invalidIndex("button", index) }
        desiredButtons[index] = light
        guard cachedButton(index) != light else { return [] }
        storeButton(index, light)
        return try [map.buttonLight(button: index, light: light, style: lightProtocol)]
    }

    public mutating func setRing(_ index: Int, display: RingDisplay) throws -> [MIDIMessage] {
        guard (1 ... 16).contains(index) else { throw CompactError.invalidIndex("encoder", index) }
        #if DEBUG
            if feedbackSchedulerReference != nil {
                try feedbackIntent(.request(key: "ring.\(index)", message: map.encoderRingValue(encoder: index, display: display), provenance: feedbackCallerProvenance))
            }
        #endif
        let messages = try _setRing(index, display: display)
        #if DEBUG
            feedbackGenerated(messages)
        #endif
        return messages
    }

    private mutating func _setRing(_ index: Int, display: RingDisplay) throws -> [MIDIMessage] {
        guard (1 ... 16).contains(index) else { throw CompactError.invalidIndex("encoder", index) }
        let midi = try map.encoderRingValue(encoder: index, display: display)
        desiredRings[index] = display
        guard cachedRing(index) != display else { return [] }
        storeRing(index, display)
        return [midi]
    }

    public mutating func setRingStyle(_ index: Int, style: RingStyle) throws -> [MIDIMessage] {
        guard (1 ... 16).contains(index) else { throw CompactError.invalidIndex("encoder", index) }
        #if DEBUG
            if feedbackSchedulerReference != nil {
                try feedbackIntent(.style(key: "style.\(index)", message: map.encoderRingStyle(encoder: index, style: style), projectionKey: "ring.\(index)", provenance: feedbackCallerProvenance))
            }
            feedbackDerivedDepth += 1
        #endif
        defer {
            #if DEBUG
                feedbackDerivedDepth -= 1
            #endif
        }
        let messages = try _setRingStyle(index, style: style)
        #if DEBUG
            // Only the outer operation contributes native output; redraw is derived.
            if feedbackDerivedDepth == 1 {
                let scope = feedbackScope; let provenance = feedbackProducedProvenance(messages)
                feedbackSchedulerReference?.generated(messages, scope: scope, provenance: provenance)
            }
        #endif
        return messages
    }

    private mutating func _setRingStyle(_ index: Int, style: RingStyle) throws -> [MIDIMessage] {
        guard (1 ... 16).contains(index) else { throw CompactError.invalidIndex("encoder", index) }
        desiredStyles[index] = style
        guard cachedStyle(index) != style else { return [] }
        storeStyle(index, style)
        var result = try [map.encoderRingStyle(encoder: index, style: style)]
        // Changing ring style locally redraws the ring: replay the host-owned position.
        clearRingCache(index)
        if let display = desiredRings[index] {
            result += try setRing(index, display: display)
        }
        return result
    }

    public mutating func invalidateNonMotorFeedback() {
        #if DEBUG
            if feedbackSchedulerReference != nil {
                feedbackIntent(.invalidate(keys: (1 ... 39).map { "button.\($0)" } + (1 ... 16).flatMap { ["ring.\($0)", "style.\($0)"] }))
            }
        #endif
        clearButtonCache()
        clearRingCache()
        clearStyleCache()
    }

    public mutating func invalidateMotorCommandHistory() {
        lastMotorCommands.removeAll()
        observedIsCurrent.removeAll()
    }

    public mutating func restoreNonMotorFeedback() throws -> [MIDIMessage] {
        #if DEBUG
            if feedbackSchedulerReference != nil {
                feedbackIntent(.refresh(order: (1 ... 16).map { "style.\($0)" } + (1 ... 16).map { "ring.\($0)" } + (1 ... 39).map { "button.\($0)" }))
            }
            feedbackDerivedDepth += 1
        #endif
        defer {
            #if DEBUG
                feedbackDerivedDepth -= 1
            #endif
        }
        var result: [MIDIMessage] = []
        for index in desiredStyles.keys.sorted() {
            if let style = desiredStyles[index] {
                result += try setRingStyle(index, style: style)
            }
        }
        for index in desiredRings.keys.sorted() {
            if let display = desiredRings[index] {
                result += try setRing(index, display: display)
            }
        }
        for index in desiredButtons.keys.sorted() {
            if let light = desiredButtons[index] {
                result += try setButton(index, light: light)
            }
        }
        #if DEBUG
            if feedbackDerivedDepth == 1 {
                let scope = feedbackScope; let provenance = feedbackProducedProvenance(result)
                feedbackSchedulerReference?.generated(result, scope: scope, provenance: provenance)
            }
        #endif
        return result
    }
}

public extension CompactState {
    /// A profile change never carries a queued motor intent across configuration boundaries.
    /// Physical touch survives so subsequent writes cannot race a hand already on a fader.
    func reconfigured(map: FactoryStandardMap, lightProtocol: ButtonLightProtocol) -> CompactState {
        var next = CompactState(map: map, lightProtocol: lightProtocol)
        #if DEBUG
            next.feedbackCallerProvenance = feedbackCallerProvenance
            next.feedbackSchedulerReference = feedbackSchedulerReference
            next.feedbackSchedulerReference?.reset()
        #endif
        next.resourceScope = resourceScope
        next.resourceScope.transmitChannel = map.transmitChannel
        next.resourceScope.receiveChannel = map.globalReceiveChannel
        next.resourceScope.lightProtocol = lightProtocol.rawValue
        next.layer = layer
        next.touchedFaders = touchedFaders
        next.safetyTouches = safetyTouches
        next.observedLayer = observedLayer
        next.observationRevision = observationRevision
        next.layerObservationRevision = layerObservationRevision
        next.faderObservationRevisions = faderObservationRevisions
        next.observedFaders = observedFaders
        next.pressedButtons = pressedButtons
        next.pushedEncoders = pushedEncoders
        next.desiredButtons = desiredButtons
        next.desiredRings = desiredRings
        next.desiredStyles = desiredStyles
        return next
    }
}

public struct CompactPendingMotorFact: Equatable, Sendable {
    public let index: Int
    public let target: UInt8?
    public let observed: UInt8?
    public let touched: Bool
    public let provenance: CompactPlannedProvenance?
    /// Unknown origin cannot prove consumption; payload equality alone is insufficient.
    public func matchesProducedPlan(_ message: MIDIMessage, provenance produced: CompactPlannedProvenance?, map: FactoryStandardMap) throws -> Bool {
        guard let provenance, let produced, provenance == produced, let target else { return false }
        return try map.motorPosition(fader: index, value: target) == message
    }

    public init(index: Int, target: UInt8?, observed: UInt8?, touched: Bool, provenance: CompactPlannedProvenance?) {
        self.index = index; self.target = target; self.observed = observed; self.touched = touched; self.provenance = provenance
    }
}
