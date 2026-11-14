import Testing
@testable import XTouchCompactCore

@Test func disabledDeviceAccessNeverInvokesCoreMIDIOrScriptFactory() throws {
    var enabledFactoryCalls = 0
    var disabledFactoryCalls = 0
    let selected = try HardwareDeviceAccess.disabled.make(testInjectionRequested: false, disabled: {
        disabledFactoryCalls += 1
        return "disconnected-no-device-access"
    }, enabled: {
        enabledFactoryCalls += 1
        Issue.record("CoreMIDI/script factory must be unreachable")
        return "forbidden"
    })
    #expect(selected == "disconnected-no-device-access")
    #expect(enabledFactoryCalls == 0)
    #expect(disabledFactoryCalls == 1)
}

@Test func disabledDeviceAccessRejectsTestInjectionBeforeAnyFactory() throws {
    var calls = 0
    do {
        let _: String = try HardwareDeviceAccess.disabled.make(testInjectionRequested: true, disabled: {
            calls += 1; return "disabled"
        }, enabled: {
            calls += 1; return "forbidden"
        })
        Issue.record("Test injection cannot be combined with disabled device access")
    } catch HardwareDeviceAccess.SelectionError.disabledRejectsTestInjection {}
    #expect(calls == 0)
}

@Test func enabledDeviceAccessPreservesTheExplicitTransportFactory() throws {
    var enabledFactoryCalls = 0
    var disabledFactoryCalls = 0
    let selected = try HardwareDeviceAccess.enabled.make(testInjectionRequested: true, disabled: {
        disabledFactoryCalls += 1; return "disabled"
    }, enabled: {
        enabledFactoryCalls += 1; return "existing-selection"
    })
    #expect(selected == "existing-selection")
    #expect(enabledFactoryCalls == 1)
    #expect(disabledFactoryCalls == 0)
}
