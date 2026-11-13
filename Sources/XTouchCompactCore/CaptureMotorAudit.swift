import Foundation

public enum CaptureAuditAssessment: String, Codable, Sendable {
    case violations, inconclusive
    case noRecordedViolations = "no-recorded-violations"
}

public struct CaptureStateBoundary: Equatable, Codable, Sendable {
    public let sequence: Int
    public let reason: String
}

public struct CaptureReleaseWindow: Equatable, Codable, Sendable {
    public let fader: Int
    public let releaseSequence: Int
    public internal(set) var motorSequences: [Int] = []
    public internal(set) var endSequence = 0
    public internal(set) var endReason = ""
    public internal(set) var motorCount = 0
}

/// Same recorded-evidence rules as tools/audit_motor_safety.py. The App computes
/// SHA-256 from the frozen source bytes; no hardware qualification is represented.
public struct CaptureMotorAudit: Equatable, Codable, Sendable {
    public internal(set) var schemaVersion = 1
    public internal(set) var eventCount = 0
    public internal(set) var complete = false
    public internal(set) var evidenceSufficient = false
    public internal(set) var assessment: CaptureAuditAssessment = .inconclusive
    public internal(set) var motorOutputs = 0
    public internal(set) var layerAssertions = 0
    public internal(set) var motorWhileTouched: [Int] = []
    public internal(set) var motorDuringLayerMismatch: [Int] = []
    public internal(set) var layerAssertionWhileTouched: [Int] = []
    public internal(set) var releaseWindows: [CaptureReleaseWindow] = []
    public internal(set) var motorWithUnknownTouch: [Int] = []
    public internal(set) var motorWithUnknownLayer: [Int] = []
    public internal(set) var motorWithUnknownRoute: [Int] = []
    public internal(set) var layerAssertionWithUnknownTouch: [Int] = []
    public internal(set) var layerAssertionWithUnknownRoute: [Int] = []
    public internal(set) var outputsWithUnknownDelivery: [Int] = []
    public internal(set) var stateBoundaries: [CaptureStateBoundary] = []
    public internal(set) var recordedViolationCount = 0
}

public extension CaptureMotorAudit {
    init(capture: RecordedCapture) {
        var review = Self()
        review.eventCount = capture.events.count; review.complete = capture.isComplete
        var route = capture.session.route, mode = capture.session.hardwareMode
        var tx = capture.session.transmitChannel
        var touches: [Int: Bool] = [:], observedLayer: CompactLayer?
        var active: [Int: Int] = [:]
        func finish(_ fader: Int, reason: String, sequence: Int) {
            guard let index = active.removeValue(forKey: fader) else { return }
            review.releaseWindows[index].endReason = reason
            review.releaseWindows[index].endSequence = sequence
            review.releaseWindows[index].motorCount = review.releaseWindows[index].motorSequences.count
        }
        func boundary(_ reason: String, sequence: Int) {
            for fader in active.keys.sorted() {
                finish(fader, reason: reason, sequence: sequence)
            }
            observedLayer = nil; touches = touches.filter(\.value)
            review.stateBoundaries.append(.init(sequence: sequence, reason: reason))
        }
        for event in capture.events {
            let sequence = event.sequence
            if event.hardwareMode != mode {
                boundary("hardware-mode-change", sequence: sequence); mode = event.hardwareMode
            }
            if let tx, event.transmitChannel != tx {
                boundary("transmit-channel-change", sequence: sequence)
            }
            tx = event.transmitChannel
            if let nextRoute = event.connection {
                if nextRoute != route || !nextRoute.isKnown {
                    boundary("connection-change", sequence: sequence)
                }
                route = nextRoute
            }
            guard event.rawMIDI1Bytes != nil, event.source != .mock else { continue }
            if event.direction == .input {
                guard !event.ignored, let input = event.decodedInput else { continue }
                if event.hardwareMode {
                    observedLayer = input.layer
                }
                if case let .faderTouch(index) = input.control {
                    let pressed = input.isPressed == true, previous = touches[index]
                    touches[index] = pressed
                    if pressed {
                        finish(index, reason: "next-touch", sequence: sequence)
                    } else if previous != false {
                        active[index] = review.releaseWindows.count
                        review.releaseWindows.append(.init(fader: index, releaseSequence: sequence))
                    }
                }
                continue
            }
            guard event.hardwareMode else { continue }
            let fader = event.motorFader, assertion = event.isLayerAssertion
            guard event.delivery == "sent" else {
                if fader != nil || assertion, event.delivery != "suppressed", event.delivery != "failed" {
                    review.outputsWithUnknownDelivery.append(sequence)
                }
                continue
            }
            if let fader {
                review.motorOutputs += 1
                if touches[fader] == true {
                    review.motorWhileTouched.append(sequence)
                }
                if touches[fader] == nil {
                    review.motorWithUnknownTouch.append(sequence)
                }
                if !route.isKnown {
                    review.motorWithUnknownRoute.append(sequence)
                }
                if let observedLayer {
                    if observedLayer != event.hostLayer {
                        review.motorDuringLayerMismatch.append(sequence)
                    }
                } else {
                    review.motorWithUnknownLayer.append(sequence)
                }
                if let index = active[fader] {
                    review.releaseWindows[index].motorSequences.append(sequence)
                }
            }
            if assertion {
                review.layerAssertions += 1
                if touches.values.contains(true) {
                    review.layerAssertionWhileTouched.append(sequence)
                }
                if touches.count < 9 {
                    review.layerAssertionWithUnknownTouch.append(sequence)
                }
                if !route.isKnown {
                    review.layerAssertionWithUnknownRoute.append(sequence)
                }
                observedLayer = nil
            }
        }
        for fader in active.keys.sorted() {
            finish(fader, reason: capture.isComplete ? "capture-end" : "incomplete-prefix", sequence: capture.events.count)
        }
        review.recordedViolationCount = review.motorWhileTouched.count + review.motorDuringLayerMismatch.count + review.layerAssertionWhileTouched.count
        review.evidenceSufficient = review.complete && [review.motorWithUnknownTouch, review.motorWithUnknownLayer, review.motorWithUnknownRoute,
                                                        review.layerAssertionWithUnknownTouch, review.layerAssertionWithUnknownRoute, review.outputsWithUnknownDelivery].allSatisfy(\.isEmpty)
        review.assessment = review.recordedViolationCount > 0 ? .violations : review.evidenceSufficient ? .noRecordedViolations : .inconclusive
        self = review
    }
}
