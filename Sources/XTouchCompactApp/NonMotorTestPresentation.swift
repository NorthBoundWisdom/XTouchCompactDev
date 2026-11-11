#if os(macOS)
    import Foundation
    import XTouchCompactCore

    // Frontend contract for the diagnostic workspace. These are presentation
    // values and editable intents; encoding and authorization stay in Core/model.

    struct NonMotorTestPresentation: Equatable, Sendable {
        var approval: NonMotorTestApproval?
        var attempts: [NonMotorAttemptPresentation] = []
        var preview: NonMotorPreviewPresentation?
        var lastLockReason: String?
        var canRequestPermission = false
        var canRecordObservation = false
    }

    struct NonMotorPreviewPresentation: Equatable, Sendable {
        let command: NonMotorTestCommand
        let message: MIDIMessage
        /// Explicit preview channel, displayed as 1...16. This is not a detected RX value.
        let receiveChannel: Int
    }

    struct NonMotorAttemptPresentation: Equatable, Identifiable, Sendable {
        let id: String
        let timestamp: Date
        let command: NonMotorTestCommand
        let message: MIDIMessage
        let delivery: MonitorEvent.Delivery
        let reportedResponse: NonMotorReportedResponse?
        let note: String?
    }

    enum NonMotorCommandKind: String, CaseIterable, Identifiable {
        case button, ring, style, layer
        var id: Self {
            self
        }

        var titleKey: String {
            switch self { case .button: "Button LED test"; case .ring: "Ring display test"; case .style: "Ring style test"; case .layer: "Layer assertion test" }
        }
    }

    enum NonMotorRingChoice: String, CaseIterable, Identifiable {
        case off, position, blinkingPosition, allOn, allBlinking
        var id: Self {
            self
        }
    }

    /// Editable intent data only. MIDI encoding and permission rules remain in the backend.
    struct NonMotorCommandDraft {
        var kind: NonMotorCommandKind = .button
        var button = 1
        var light: ButtonLight = .off
        var variant: ButtonLightProtocol = .manual
        var encoder = 1
        var ring: NonMotorRingChoice = .position
        var segment = 7
        var style: RingStyle = .single
        var layer: CompactLayer = .a

        var command: NonMotorTestCommand {
            switch kind {
            case .button: return .button(button, light, variant)
            case .style: return .style(encoder, style)
            case .layer: return .layer(layer)
            case .ring:
                let display: RingDisplay = switch ring {
                case .off: .off
                case .position: .position(segment)
                case .blinkingPosition: .blinkingPosition(segment)
                case .allOn: .allOn
                case .allBlinking: .allBlinking
                }
                return .ring(encoder, display)
            }
        }
    }
#endif
