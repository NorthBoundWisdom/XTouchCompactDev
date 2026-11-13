import Foundation

public enum CaptureReplayDisposition: String, Equatable, Sendable {
    case input, safetyTouch, recordedOutputSkipped, boundary, ignored
}

/// Isolated neutral host + mock. It has no transport, callbacks, plugins, external
/// clock or reference to the live ConsoleModel. Recorded OUT is never executed.
public struct RecordedCaptureReplay: Sendable {
    public let capture: RecordedCapture
    public private(set) var cursor = 0
    public private(set) var session: CompactSession
    public private(set) var mock: MockXTouchCompact
    public private(set) var lastSequence: Int?
    public private(set) var lastDisposition: CaptureReplayDisposition?
    public private(set) var inputsReplayed = 0
    public private(set) var recordedOutputsSkipped = 0
    public private(set) var generatedFeedbackCount = 0
    public private(set) var ignoredActionCount = 0
    public private(set) var boundaryCount = 0
    private var route: CaptureRoute
    private var mode: Bool?
    private var transmitChannel: UInt8?

    public var isAtEnd: Bool {
        cursor >= capture.events.count
    }

    public var usesFallbackProfile: Bool {
        capture.session.transmitChannel == nil || capture.session.receiveChannel == nil || capture.session.lightProtocol == nil
    }

    public init(capture: RecordedCapture) throws {
        self.capture = capture
        let map = try FactoryStandardMap(transmitChannel: (capture.session.transmitChannel ?? 1) - 1,
                                         globalReceiveChannel: (capture.session.receiveChannel ?? 1) - 1)
        let lights = capture.session.lightProtocol ?? .manual
        session = CompactSession(map: map, lightProtocol: lights)
        mock = MockXTouchCompact(map: map, lightProtocol: lights)
        _ = try session.connect(assertLayer: false)
        route = capture.session.route; mode = capture.session.hardwareMode; transmitChannel = capture.session.transmitChannel
    }

    @discardableResult public mutating func step() throws -> Bool {
        guard !isAtEnd else { return false }
        var next = self
        try next.consume(capture.events[cursor])
        next.cursor += 1
        self = next
        return true
    }

    public mutating func reset() throws {
        self = try Self(capture: capture)
    }

    /// Explicit simulation-only write, useful for inspecting touch deferral/release.
    /// Original parameter configuration and software writes are absent from the file.
    public mutating func setFader(_ index: Int, value: UInt8) throws {
        guard value < 128 else { throw CompactError.invalidMIDIValue(value) }
        var next = self
        let messages = try next.session.setFader(index, value: value)
        next.deliverToMock(messages)
        self = next
    }

    private mutating func boundary() throws {
        _ = try session.connect(assertLayer: false)
        boundaryCount += 1
    }

    private mutating func consume(_ event: RecordedCaptureEvent) throws {
        lastSequence = event.sequence; lastDisposition = .ignored
        if event.hardwareMode != mode {
            try boundary(); mode = event.hardwareMode; lastDisposition = .boundary
        }
        if let transmitChannel, transmitChannel != event.transmitChannel {
            try boundary(); lastDisposition = .boundary
        }
        transmitChannel = event.transmitChannel
        if let next = event.connection {
            if next != route || !next.isKnown {
                try boundary(); lastDisposition = .boundary
            }
            route = next
        }
        let rx = event.receiveChannel.map { $0 - 1 } ?? session.state.map.globalReceiveChannel
        let lights = event.lightProtocol ?? session.state.lightProtocol
        if session.state.map.transmitChannel != event.transmitChannel - 1 || session.state.map.globalReceiveChannel != rx || session.state.lightProtocol != lights {
            let map = try FactoryStandardMap(transmitChannel: event.transmitChannel - 1, globalReceiveChannel: rx)
            _ = try session.reconfigure(map: map, lightProtocol: lights) // Intent only; discard produced feedback.
            mock = mock.reconfigured(map: map, lightProtocol: lights)
        }
        if session.state.layer != event.hostLayer {
            _ = try session.selectHostLayer(event.hostLayer)
        }
        if event.direction == .output {
            recordedOutputsSkipped += 1; lastDisposition = .recordedOutputSkipped
            if event.hardwareMode, event.source != .mock, event.delivery == "sent", event.isLayerAssertion {
                // Only invalidate old evidence. Do not apply the Program Change to Mock.
                session.didTransmitLayerAssertion()
            }
            return
        }
        guard event.direction == .input, event.delivery == "received", !event.ignored, let message = event.message else { return }
        if event.source == .hardware, let input = event.decodedInput, case let .faderTouch(index) = input.control {
            session.setSafetyTouch(index, touched: input.isPressed == true)
            lastDisposition = .safetyTouch
        }
        let active = event.hardwareMode ? event.source == .hardware : event.source == .mock
        guard active, try mock.applyCapturedInput(message) != nil else { return }
        let update = try session.receive([message])
        inputsReplayed += update.inputs.count
        ignoredActionCount += update.actionIntents.count // Never execute an Agent/business action.
        deliverToMock(update.feedback)
        lastDisposition = .input
    }

    private mutating func deliverToMock(_ messages: [MIDIMessage]) {
        let permitted = session.filterFeedbackForDelivery(messages)
        generatedFeedbackCount += permitted.count
        mock.receive(permitted)
    }
}
