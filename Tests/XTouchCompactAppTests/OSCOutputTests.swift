#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore
    import XTouchCompactLocalization

    @MainActor private final class FakeOSC: OSCTransport {
        var starts = 0
        var stops = 0
        var packets: [Data] = []
        var failure: ((any Error) -> Void)?
        func start(host _: String, port _: UInt16, onFailure: @escaping (any Error) -> Void) throws {
            starts += 1; failure = onFailure
        }

        func send(_ data: Data) {
            packets.append(data)
        }

        func stop() {
            stops += 1; failure = nil
        }
    }

    @Test @MainActor func oscSchedulerKeepsStationaryValuesAndTripsAfterActualPause() {
        let clock = TestClock()
        let transport = FakeOSC()
        let model = ConsoleModel(startsMIDI: false, now: { clock.date }, oscTransport: transport)
        telemetry(model, clock)
        model.setOSCEnabled(true)
        model.setOSCEnabled(true)
        #expect(transport.starts == 1)
        clock.time += 0.25
        model.setParameter(model.oscParameter, value: 127)
        telemetry(model, clock)
        model.tickOSC()
        #expect(model.oscOutput == 0.0625)
        #expect(transport.packets.count == 1)
        for _ in 0 ..< 40 {
            clock.time += 0.25
            telemetry(model, clock) // Independent trusted destination telemetry fixture.
            model.tickOSC() // No new parameter writes for ten seconds.
            #expect(model.oscEnabled)
        }
        #expect(transport.packets.count == 41)
        clock.time += 0.31 // An actual scheduler pause must trip before refreshing.
        model.tickOSC()
        #expect(!model.oscEnabled)
        #expect(transport.stops == 1)
        #expect(model.notifications.contains { $0.id == "osc" })
        telemetry(model, clock)
        model.setOSCEnabled(true)
        model.oscParameter = "missing"
        model.tickOSC()
        #expect(!model.oscEnabled)
        #expect(model.notifications.first(where: { $0.id == "osc" })?.message?.key.contains("invalid") == true)
        model.oscParameter = "a.Fader.1"
        telemetry(model, clock)
        model.setOSCEnabled(true)
        transport.failure?(OSCError.invalidAddress)
        #expect(!model.oscEnabled)
        #expect(model.notifications.contains { $0.id == "osc" })
    }

    @Test @MainActor func oscInvalidDestinationUsesOSCError() {
        let transport = NetworkOSCTransport()
        #expect(throws: OSCError.self) { try transport.start(host: "", port: 9000, onFailure: { _ in }) }
        #expect(throws: OSCError.self) { try transport.start(host: "127.0.0.1", port: 0, onFailure: { _ in }) }
    }

    @Test @MainActor func stationaryInitialValueSurvivesWithoutAnyWrite() {
        let clock = TestClock()
        let transport = FakeOSC()
        let model = ConsoleModel(startsMIDI: false, now: { clock.date }, oscTransport: transport)
        telemetry(model, clock)
        model.setOSCEnabled(true)
        for _ in 0 ..< 60 {
            clock.time += 0.25
            telemetry(model, clock)
            model.tickOSC()
        }
        #expect(model.oscEnabled)
        #expect(transport.packets.count == 60)
        #expect(model.oscOutput == 0)
        #expect(!model.notifications.contains { $0.id == "osc" })
    }

    @MainActor private func telemetry(_ model: ConsoleModel, _: TestClock) {
        model.receiveTrustedOSCActual(0, at: model.runtimeTime)
        model.receiveTrustedOSCHeartbeat(at: model.runtimeTime)
    }

    @Test @MainActor func requestsAndSchedulerDoNotManufactureActualFeedback() {
        let clock = TestClock()
        let transport = FakeOSC()
        let model = ConsoleModel(startsMIDI: false, now: { clock.date }, oscTransport: transport)
        model.setParameter(model.oscParameter, value: 127)
        model.setOSCEnabled(true)
        #expect(!model.oscEnabled && transport.starts == 0 && transport.packets.isEmpty)
        #expect(model.notifications.first(where: { $0.id == "osc" })?.message?.key.contains("trusted actual") == true)
        model.receiveTrustedOSCActual(0, at: model.runtimeTime)
        #expect(model.trustedOSCActual?.time == model.runtimeTime)
        #expect(model.trustedOSCHeartbeat == nil)
        model.setOSCEnabled(true)
        #expect(!model.oscEnabled && transport.packets.isEmpty)
        model.receiveTrustedOSCHeartbeat(at: model.runtimeTime)
        #expect(model.trustedOSCActual == nil)
        model.setOSCEnabled(true)
        #expect(!model.oscEnabled && transport.packets.isEmpty)
        telemetry(model, clock)
        model.setOSCEnabled(true)
        clock.time += 0.31
        model.receiveTrustedOSCActual(0, at: model.runtimeTime) // Actual alone cannot refresh heartbeat.
        #expect(model.runtimeTime - (model.trustedOSCActual?.time ?? -.infinity) < 0.3)
        #expect(model.runtimeTime - (model.trustedOSCHeartbeat ?? .infinity) >= 0.3)
        model.tickOSC()
        #expect(!model.oscEnabled && transport.packets.isEmpty)
    }

    @Test @MainActor func invalidTelemetryTimestampClosesReadyOutputImmediately() {
        for invalidHeartbeat in [true, false] {
            let clock = TestClock()
            let transport = FakeOSC()
            let model = ConsoleModel(startsMIDI: false, now: { clock.date }, oscTransport: transport)
            telemetry(model, clock)
            model.setOSCEnabled(true)
            clock.time += 0.25
            telemetry(model, clock)
            model.tickOSC()
            #expect(model.oscEnabled && transport.packets.count == 1)
            if invalidHeartbeat {
                model.receiveTrustedOSCHeartbeat(at: .nan)
            } else {
                model.receiveTrustedOSCActual(0, at: .infinity)
            }
            #expect(!model.oscEnabled)
            clock.time += 0.1
            model.tickOSC()
            #expect(transport.packets.count == 1)
            #expect(model.notifications.first(where: { $0.id == "osc" })?.message?.key.contains("timestamp") == true)
        }
    }

    @Test @MainActor func outputRefusesUnsafeDoubleSeedAndAcceptsActualFloatMeasurement() throws {
        let clock = TestClock()
        let transport = FakeOSC()
        let model = ConsoleModel(startsMIDI: false, now: { clock.date }, oscTransport: transport)
        model.receiveTrustedOSCActual(0.1, at: model.runtimeTime)
        model.receiveTrustedOSCHeartbeat(at: model.runtimeTime)
        model.setOSCEnabled(true)
        #expect(!model.oscEnabled && transport.packets.isEmpty)
        let reason = try #require(model.notifications.first(where: { $0.id == "osc" })?.message)
        #expect(reason.key == "OSC output stopped: actual feedback precision cannot be used safely for OSC.")
        #expect(Localizer(language: .simplifiedChinese).text(reason).contains("实际反馈精度不能安全"))
        #expect(Localizer(language: .traditionalChinese).text(reason).contains("實際回饋精度無法安全"))
        // This fact originates in an actual Float sample, not a rounded arbitrary Double.
        let measured: Float = 0.25
        model.receiveTrustedOSCActual(Double(measured), at: model.runtimeTime)
        model.receiveTrustedOSCHeartbeat(at: model.runtimeTime)
        model.setOSCEnabled(true) // Explicit enable performs the host's off/on sequence.
        #expect(model.oscEnabled)
        clock.time += 0.25
        model.receiveTrustedOSCActual(Double(measured), at: model.runtimeTime)
        model.receiveTrustedOSCHeartbeat(at: model.runtimeTime)
        model.tickOSC()
        #expect(model.oscEnabled && transport.packets.count == 1)
        #expect(try transport.packets.first == (OSCCodec.encode(address: "/xtouch/value", value: 0.1875)))
    }
#endif
