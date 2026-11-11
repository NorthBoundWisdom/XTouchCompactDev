#if os(macOS)
    import Foundation
    import Testing
    @testable import XTouchCompactApp
    import XTouchCompactCore

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
        model.setOSCEnabled(true)
        model.setOSCEnabled(true)
        #expect(transport.starts == 1)
        clock.time += 0.5
        model.setParameter(model.oscParameter, value: 127)
        model.tickOSC()
        #expect(model.oscOutput == 0.125)
        #expect(transport.packets.count == 1)
        for _ in 0 ..< 40 {
            clock.time += 0.25
            model.tickOSC() // No new parameter writes for ten seconds.
            #expect(model.oscEnabled)
        }
        #expect(transport.packets.count == 41)
        clock.time += 1.1 // An actual scheduler pause must trip before refreshing.
        model.tickOSC()
        #expect(!model.oscEnabled)
        #expect(transport.stops == 1)
        #expect(model.notifications.contains { $0.id == "osc" })
        model.setOSCEnabled(true)
        model.oscParameter = "missing"
        model.tickOSC()
        #expect(!model.oscEnabled)
        #expect(model.notifications.first(where: { $0.id == "osc" })?.message?.key.contains("invalid") == true)
        model.oscParameter = "a.Fader.1"
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
        model.setOSCEnabled(true)
        for _ in 0 ..< 60 {
            clock.time += 0.25
            model.tickOSC()
        }
        #expect(model.oscEnabled)
        #expect(transport.packets.count == 60)
        #expect(model.oscOutput == 0)
        #expect(!model.notifications.contains { $0.id == "osc" })
    }
#endif
