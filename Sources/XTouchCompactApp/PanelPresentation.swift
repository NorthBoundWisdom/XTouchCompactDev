#if os(macOS)
    import Foundation
    import XTouchCompactCore
    import XTouchCompactLocalization

    // Frontend contract.
//
    // Views render these value types and emit `PanelIntents`; they never talk to the session,
    // CoreMIDI or the mock directly. The view model fills the snapshot. Optional fields mean
    // "the backend does not report this yet": the UI hides the corresponding readout instead of
    // inventing a value. See TODO.md for the backend work that fills each optional.

    /// CoreMIDI endpoint identity; never use transient port indices as persistence keys.
    struct CompactMIDIEndpoint: Equatable, Sendable, Identifiable {
        var id: Int32
        var name: String
    }

    struct CompactMIDIConnection: Equatable, Sendable {
        var generation: UInt64 = 0
        var inputs: [CompactMIDIEndpoint] = []
        var outputs: [CompactMIDIEndpoint] = []
        var connectedInput: CompactMIDIEndpoint?
        var connectedOutput: CompactMIDIEndpoint?
        var error: LocalizedMessage?

        var isConnected: Bool {
            connectedInput != nil && connectedOutput != nil
        }
    }

    struct FaderPresentation: Equatable, Identifiable, Sendable {
        let index: Int
        /// Host-desired position (the application parameter), 0...127.
        var target: UInt8
        /// Last position the device reported. Differs from `target` while a motor move is outstanding.
        var observed: UInt8?
        var isTouched: Bool?
        /// A motor command is being withheld because the fader is touched.
        var isMotorPending: Bool?
        var label: String?
        var detail: String?
        var followsObservedPosition = false

        var id: Int {
            index
        }

        var isMaster: Bool {
            index == PanelLayout.masterFader
        }

        /// A host write may change target while a hand still owns the physical cap.
        var capPosition: UInt8 {
            followsObservedPosition || isTouched == true ? observed ?? target : target
        }
    }

    struct EncoderPresentation: Equatable, Identifiable, Sendable {
        let index: Int
        var value: UInt8
        /// What the host asked the LED ring to show.
        var ring: RingDisplay
        var style: RingStyle?
        var isPushed: Bool?
        var label: String?
        var detail: String?
        var observedValue: UInt8?
        var observesInput = false

        var id: Int {
            index
        }
    }

    struct ButtonPresentation: Equatable, Identifiable, Sendable {
        let index: Int
        var light: ButtonLight
        var isDown: Bool?
        var label: String?

        var id: Int {
            index
        }
    }

    /// Where a control's messages travel. Input and feedback addresses differ on this device.
    struct ControlAddressing: Equatable, Sendable {
        var input: String
        var feedback: String?
    }

    /// Physical-input facts for the observation workspace; nil readings remain unknown.
    /// The adapter converts core channels to display numbers without changing a profile.
    struct HardwareObservationPresentation: Equatable, Sendable {
        var messageCount = 0
        var recent: [ObservedHardwareInput] = []
        var faderPositions: [Int: UInt8] = [:]
        var faderTouches: [Int: Bool] = [:]
        var encoderValues: [CompactLayer: [Int: UInt8]] = [:]
        var encoderPushes: [Int: Bool] = [:]
        var buttonPresses: [Int: Bool] = [:]
        var seenControls: Set<CompactControl> = []
        var inputLayer: CompactLayer?
        var isPreview = false
        var reviewLayers: [LayerInputReviewPresentation] = []
        var crossLayerReleases: [CrossLayerReleasePresentation] = []
        var exportedReview: EvidenceExportPresentation?

        var latest: ObservedHardwareInput? {
            recent.first
        }

        var touchedFaders: [Int] {
            faderTouches.filter(\.value).keys.sorted()
        }

        func encoderValue(_ index: Int) -> UInt8? {
            guard let inputLayer else { return nil }
            return encoderValues[inputLayer]?[index]
        }

        var coverage: [ObservationCoveragePresentation] {
            [
                .init(title: "Faders", count: seenControls.filter {
                    if case .fader = $0 {
                        true
                    } else {
                        false
                    }
                }.count, total: CompactGeometry.faderCount),
                .init(title: "Touches", count: seenControls.filter {
                    if case .faderTouch = $0 {
                        true
                    } else {
                        false
                    }
                }.count, total: CompactGeometry.faderCount),
                .init(title: "Encoders", count: seenControls.filter {
                    if case .encoder = $0 {
                        true
                    } else {
                        false
                    }
                }.count, total: CompactGeometry.encoderCount),
                .init(title: "Pushes", count: seenControls.filter {
                    if case .encoderPush = $0 {
                        true
                    } else {
                        false
                    }
                }.count, total: CompactGeometry.encoderCount),
                .init(title: "Buttons", count: seenControls.filter {
                    if case .button = $0 {
                        true
                    } else {
                        false
                    }
                }.count, total: CompactGeometry.buttonCount),
            ]
        }
    }

    struct InputReviewRowPresentation: Equatable, Identifiable, Sendable {
        let control: CompactControl
        let group: CompactInputGroup
        let review: ControlInputReview
        var id: CompactControl {
            control
        }

        var hasInputCoverage: Bool {
            group.requiresPressRelease ? review.pairCount > 0 : review.minimum == 0 && review.maximum == 127
        }

        var hasAnomalies: Bool {
            review.duplicatePressCount > 0 || review.unmatchedReleaseCount > 0
        }

        var rangeText: String {
            guard let minimum = review.minimum, let maximum = review.maximum else { return "—" }
            return "\(minimum)–\(maximum)"
        }

        var statusKey: String {
            if review.eventCount == 0 {
                return "No input yet"
            }
            if hasAnomalies {
                return "Review pairing"
            }
            if hasInputCoverage {
                return group.requiresPressRelease ? "Paired" : "0–127 received"
            }
            return group.requiresPressRelease ? "Press/release needed" : "Range incomplete"
        }
    }

    struct LayerInputReviewPresentation: Equatable, Identifiable, Sendable {
        let layer: CompactLayer
        let rows: [InputReviewRowPresentation]
        var id: CompactLayer {
            layer
        }

        var observedCount: Int {
            rows.filter { $0.review.eventCount > 0 }.count
        }

        var coveredCount: Int {
            rows.filter(\.hasInputCoverage).count
        }
    }

    struct CrossLayerReleasePresentation: Equatable, Identifiable, Sendable {
        let control: CompactControl
        let pressedLayer: CompactLayer
        let releasedLayer: CompactLayer
        let interveningLayer: CompactLayer?
        let count: Int
        var id: String {
            control.description + pressedLayer.rawValue + releasedLayer.rawValue + (interveningLayer?.rawValue ?? "-")
        }
    }

    struct EvidenceExportPresentation: Equatable, Sendable {
        let path: String
        let sha256: String
        let captureSnapshotPath: String?
    }

    extension CompactInputGroup {
        var titleKey: String {
            switch self {
            case .faders: "Faders"
            case .touches: "Touches"
            case .encoders: "Encoders"
            case .pushes: "Pushes"
            case .buttons: "Buttons"
            }
        }
    }

    struct ObservationCoveragePresentation: Equatable, Identifiable, Sendable {
        let title: String
        let count: Int
        let total: Int
        var id: String {
            title
        }
    }

    struct ObservedHardwareInput: Equatable, Identifiable, Sendable {
        let id: Int
        let timestamp: Date
        let message: MIDIMessage
        let input: CompactInput?
        /// Human-facing MIDI channel, 1...16.
        let channel: Int
        let matchesConfiguredChannel: Bool

        var panelControl: CompactControl? {
            switch input?.control {
            case let .faderTouch(index): .fader(index)
            case let .encoderPush(index): .encoder(index)
            default: input?.control
            }
        }
    }

    struct PanelSnapshot: Equatable, Sendable {
        var nonMotorTests = NonMotorTestPresentation()
        var hardwareObservation: HardwareObservationPresentation?
        var listenOnly = true
        var capturePath: String?
        var notifications: [ConsoleNotification] = []
        var runtimeError: LocalizedMessage?
        var events: [MonitorEvent] = []
        var connection = CompactMIDIConnection()
        var inputChoice: Int32 = 0
        var outputChoice: Int32 = 0
        var transmitChannel = 1
        var feedbackChannel = 1
        var observedLEDVariant = false
        var layer: CompactLayer
        /// True when the panel stands in for the hardware; false when it mirrors a real device.
        var isMock: Bool
        var faders: [FaderPresentation]
        var encoders: [EncoderPresentation]
        var buttons: [ButtonPresentation]
        var pendingPreset: SurfaceConfiguration?
        var configuration: SurfaceConfiguration = .neutral
        var mcpPort: UInt16 = 8765
        var mcpEnabled = false
        var mcpWritesAllowed = false
        var mcpSimulationControlAllowed = false
        var oscEnabled = false
        var oscHost = "127.0.0.1"
        var oscPort: UInt16 = 9000
        var oscParameter = ""
        var oscOutput = 0.0
        var agents: [AgentSlot] = []
        var businessPlugins: [BusinessPluginPresentation] = []
        var parameterValues: [String: Double] = [:]

        func fader(_ index: Int) -> FaderPresentation? {
            faders.first { $0.index == index }
        }

        func encoder(_ index: Int) -> EncoderPresentation? {
            encoders.first { $0.index == index }
        }

        func button(_ index: Int) -> ButtonPresentation? {
            buttons.first { $0.index == index }
        }
    }

    /// User intent leaving the views. Panel gestures and software writes are separate on purpose:
    /// on a mock device a gesture is a physical input (it must travel the same path as real MIDI),
    /// while a software write is a host command that may move a motor. An optional intent that is
    /// nil is not supported by the backend yet and its affordance is disabled.
    struct PanelIntents {
        var armNonMotorTests: ((NonMotorTestPrerequisites) -> Void)?
        var lockNonMotorTests: (() -> Void)?
        var previewNonMotorTest: ((NonMotorTestCommand, UInt8?) -> Void)?
        var performNonMotorTest: ((NonMotorTestCommand) -> Void)?
        var recordNonMotorObservation: ((String, NonMotorReportedResponse, String) -> Void)?
        var beginHardwareObservation: (() -> Void)?
        var endHardwareObservation: (() -> Void)?
        var resetHardwareObservation: (() -> Void)?
        var exportInputReview: (() -> Void)?
        var setListenOnly: ((Bool) -> Void)?
        var startCapture: (() -> Void)?
        var stopCapture: (() -> Void)?
        var selectLayer: ((CompactLayer) -> Void)?
        var useHardware: ((Bool) -> Void)?
        var recallMotors: (() -> Void)?
        var retrySave: (() -> Void)?
        var dismissNotification: ((String) -> Void)?
        var clearMonitor: (() -> Void)?
        var selectPorts: ((Int32, Int32) -> Void)?
        var configureDevice: ((Int, Int, Bool) -> Void)?

        // Panel gestures (physical input on the mock, mirrored edit on real hardware).
        var moveFader: (_ index: Int, _ value: UInt8) -> Void
        var touchFader: ((_ index: Int, _ isTouched: Bool) -> Void)?
        var turnEncoder: (_ index: Int, _ delta: Int) -> Void
        var pushEncoder: ((_ index: Int, _ isDown: Bool) -> Void)?
        var pressButton: (_ index: Int) -> Void
        var releaseButton: ((_ index: Int) -> Void)?

        // Software writes from the inspector and workspace.
        var setFader: (_ index: Int, _ value: UInt8) -> Void
        var setEncoder: (_ index: Int, _ value: UInt8) -> Void

        /// Nil until the backend can describe MIDI addresses per control and layer.
        var setMCPEnabled: ((Bool) -> Void)?
        var setMCPWritesAllowed: ((Bool) -> Void)?
        var setMCPSimulationControlAllowed: ((Bool) -> Void)?
        var copyMCPToken: (() -> Void)?
        var setOSCEnabled: ((Bool) -> Void)?
        var configureOSC: ((String, UInt16, String) -> Void)?
        var agentPrimary: ((Int) -> Void)?
        var importConfiguration: (() -> Void)?
        var exportConfiguration: (() -> Void)?
        var realignLayer: (() -> Void)?
        var resetParameters: (() -> Void)?
        var setParameter: ((String, Double) -> Void)?
        var applyConfiguration: ((SurfaceConfiguration) -> Void)?
        var loadPreset: ((SurfaceConfiguration) -> Void)?
        var confirmLoadPreset: (() -> Void)?
        var cancelLoadPreset: (() -> Void)?
        var addressing: ((_ control: CompactControl, _ layer: CompactLayer) -> ControlAddressing?)?
    }

    extension CompactControl {
        /// Compact panel label: `F3`, `F9`, `E12`, `E12⏎`, `B27`.
        var shortName: String {
            switch self {
            case let .fader(index): "F\(index)"
            case let .faderTouch(index): "F\(index)✋"
            case let .encoder(index): "E\(index)"
            case let .encoderPush(index): "E\(index)⏎"
            case let .button(index): "B\(index)"
            }
        }

        var localizedName: String {
            localizedName(using: Localizer(language: .simplifiedChinese))
        }

        func localizedName(using l: Localizer) -> String {
            switch self {
            case let .fader(index): index == PanelLayout.masterFader ? l.text("主推子") : l.text("推子 %@", String(index))
            case let .faderTouch(index): l.text("推子 %@ 触摸", String(index))
            case let .encoder(index): l.text("编码器 %@", String(index))
            case let .encoderPush(index): l.text("编码器 %@ 按下", String(index))
            case let .button(index): PanelLayout.buttonName(index, using: l)
            }
        }
    }

    /// Fixed front-panel geometry of the X-TOUCH COMPACT: which numbered control sits where.
    /// This is hardware layout, not MIDI mapping.
    enum PanelLayout {
        static let stripCount = 8
        static let masterFader = 9
        static let masterButton = 33
        static let topEncoders = Array(1 ... 8)
        /// Right-hand encoder block, two columns by four rows, in reading order.
        static let sideEncoders = Array(9 ... 16)

        /// The three buttons between a strip's encoder and its fader, top to bottom.
        static func stripButtons(strip: Int) -> [Int] {
            [strip, 8 + strip, 16 + strip]
        }

        /// The button below a strip's fader.
        static func selectButton(strip: Int) -> Int {
            24 + strip
        }

        struct Transport: Equatable, Identifiable {
            let button: Int
            let symbol: String
            let name: String
            var id: Int {
                button
            }
        }

        /// Printed legends of the six right-hand buttons, top row then bottom row.
        static let transport: [Transport] = [
            .init(button: 34, symbol: "backward.fill", name: "快退"),
            .init(button: 35, symbol: "forward.fill", name: "快进"),
            .init(button: 36, symbol: "repeat", name: "循环"),
            .init(button: 37, symbol: "record.circle", name: "录音"),
            .init(button: 38, symbol: "stop.fill", name: "停止"),
            .init(button: 39, symbol: "play.fill", name: "播放"),
        ]

        static func buttonName(_ index: Int, using l: Localizer = Localizer(language: .simplifiedChinese)) -> String {
            switch index {
            case 1 ... 24: l.text("按键 行%@ #%@", String((index - 1) / 8 + 1), String((index - 1) % 8 + 1))
            case 25 ... 32: l.text("推子下按键 #%@", String(index - 24))
            case masterButton: l.text("主推子按键")
            default: transport.first { $0.button == index }.map { l.text("走带 · %@", String(l.text($0.name))) } ?? l.text("按键 %@", String(index))
            }
        }
    }

    /// Which of the 13 ring LEDs are lit for a host ring command.
    ///
    /// `single` is exact. The other styles approximate how the device draws a position until they
    /// are confirmed on hardware (TODO.md, HW-4); a nil style is drawn as `single`.
    enum RingLEDs {
        static let count = 13
        static let center = 7

        struct Lit: Equatable {
            var segments: Set<Int>
            var isBlinking: Bool
        }

        static func lit(_ display: RingDisplay, style: RingStyle?) -> Lit {
            switch display {
            case .off: Lit(segments: [], isBlinking: false)
            case .allOn: Lit(segments: Set(1 ... count), isBlinking: false)
            case .allBlinking: Lit(segments: Set(1 ... count), isBlinking: true)
            case let .position(position): Lit(segments: segments(position, style: style), isBlinking: false)
            case let .blinkingPosition(position): Lit(segments: segments(position, style: style), isBlinking: true)
            }
        }

        private static func segments(_ raw: Int, style: RingStyle?) -> Set<Int> {
            let position = min(max(raw, 1), count)
            switch style {
            case nil, .single?, .trim?:
                return [position]
            case .pan?:
                return Set(min(position, center) ... max(position, center))
            case .fan?:
                return Set(1 ... position)
            case .spread?:
                let reach = (position - 1) / 2
                return Set((center - reach) ... (center + reach))
            }
        }
    }

    /// Maps a 0...127 value onto fader travel. `fraction` 0 is the bottom of the slot.
    enum FaderTravel {
        static func fraction(for value: UInt8) -> Double {
            Double(min(value, 127)) / 127
        }

        /// `location` is measured from the top of a slot `length` long; the cap is `cap` tall.
        static func value(at location: Double, length: Double, cap: Double) -> UInt8 {
            let travel = length - cap
            guard travel > 0 else { return 0 }
            let fraction = 1 - (location - cap / 2) / travel
            return UInt8((min(max(fraction, 0), 1) * 127).rounded())
        }
    }
#endif
