import Foundation
import Testing
@testable import XTouchCompactCore

@Test func parameterMappingSynchronizesSharedBindingsAndHonorsTouch() throws {
    var config = SurfaceConfiguration(parameters: [ParameterDefinition(id: "gain", name: "Gain", unit: "dB", minimum: -60, maximum: 6, defaultValue: -60, step: 0.5)], assignments: [
        .init(control: .fader(1), layer: .a, action: .parameter("gain")),
        .init(control: .fader(2), layer: .a, action: .parameter("gain")),
        .init(control: .encoder(1), layer: .b, action: .parameter("gain")),
    ])
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    #expect(try session.loadConfiguration(config).allSatisfy {
        if case let .controlChange(_, n, _) = $0 {
            return !(1 ... 9).contains(n)
        }; return true
    })
    _ = try session.receive([.controlChange(channel: 0, number: 101, value: 127)])
    let messages = try session.setParameter("gain", value: -12.3)
    #expect(session.parameters.values["gain"] == -12.5)
    #expect(!messages.contains {
        if case .controlChange(_, 1, _) = $0 {
            return true
        }; return false
    })
    #expect(session.state.isMotorPending(1))
    #expect(session.bank(.a).faders[0] == session.bank(.a).faders[1])
    #expect(session.bank(.b).encoders[0] == session.bank(.a).faders[0])
    let released = try session.receive([.controlChange(channel: 0, number: 101, value: 0)])
    #expect(released.feedback.count == 1)
    config.device = "BCR2000"
    #expect(throws: ParameterError.self) { _ = try session.loadConfiguration(config) }
    #expect(session.parameters.configuration.device == "X-TOUCH COMPACT")
}

@Test func actionsAndConfigurationRoundTrip() throws {
    let definition = ParameterDefinition(id: "p", name: "Parameter", minimum: 0, maximum: 10, defaultValue: 2, step: 2, agentWritable: false)
    let actions: [ParameterAction] = [.step("p", 3), .set("p", 8), .cycle("p", [0, 4, 10]), .resetGroup("General"), .agent(8)]
    let assignments = actions.enumerated().map { ControlAssignment(control: .button($0.offset + 1), layer: .b, action: $0.element) }
    let config = SurfaceConfiguration(parameters: [definition], assignments: assignments)
    #expect(try JSONDecoder().decode(SurfaceConfiguration.self, from: JSONEncoder().encode(config)) == config)
    var engine = try ParameterEngine(configuration: config)
    #expect(throws: ParameterError.self) { _ = try engine.set("p", value: 4, fromAgent: true) }
    _ = try engine.receive(.init(control: .button(1), layer: .b, value: 127, isPressed: true))
    #expect(engine.values["p"] == 4)
    _ = try engine.receive(.init(control: .button(2), layer: .b, value: 127, isPressed: true))
    #expect(engine.values["p"] == 8)
    _ = try engine.receive(.init(control: .button(3), layer: .b, value: 127, isPressed: true))
    #expect(engine.values["p"] == 0)
    _ = try engine.receive(.init(control: .button(4), layer: .b, value: 127, isPressed: true))
    #expect(engine.values["p"] == 2)
    #expect(try engine.receive(.init(control: .button(5), layer: .b, value: 127, isPressed: true)) == PluginConfigurationAdapter.agentAction(8))
    #expect(throws: ParameterError.self) { _ = try engine.set("p", value: .nan) }
    var snapped = try ParameterEngine(configuration: SurfaceConfiguration(parameters: [definition], assignments: [
        .init(control: .button(1), layer: .a, action: .cycle("p", [1, 3])),
    ]))
    _ = try snapped.receive(.init(control: .button(1), layer: .a, value: 127, isPressed: true))
    #expect(snapped.values["p"] == 0)
    _ = try snapped.receive(.init(control: .button(1), layer: .a, value: 127, isPressed: true))
    #expect(snapped.values["p"] == 2)
}

@Test func editsAndBulkReassignmentPreserveValuesResetIsExplicit() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.setParameter("a.Fader.1", value: 83)
    var edited = session.parameters.configuration
    edited.parameters[0].name = "Edited"
    edited.assignments.append(.init(control: .button(20), layer: .a, action: .set("a.Fader.1", 42)))
    #expect(try parameterMotors(session.loadConfiguration(edited)).isEmpty)
    #expect(session.parameters.values["a.Fader.1"] == 83)
    _ = try session.loadConfiguration(edited, resetValues: true)
    #expect(session.parameters.values["a.Fader.1"] == 0)
}

private func parameterMotors(_ messages: [MIDIMessage]) -> [MIDIMessage] {
    messages.filter {
        if case let .controlChange(_, n, _) = $0 {
            return (1 ... 9).contains(n)
        }; return false
    }
}

@Test func configurationEditsPreserveUnboundTargetsOnBothLayers() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    let unbound = SurfaceConfiguration(parameters: [], assignments: [])
    _ = try session.loadConfiguration(unbound)
    _ = try session.setFader(1, value: 37, layer: .a)
    _ = try session.setEncoder(2, value: 69, layer: .a)
    _ = try session.setFader(3, value: 88, layer: .b)
    _ = try session.setEncoder(4, value: 91, layer: .b)
    let a = session.bank(.a), b = session.bank(.b)
    #expect(try parameterMotors(session.loadConfiguration(unbound)).isEmpty)
    #expect(session.bank(.a) == a)
    #expect(session.bank(.b) == b)
    _ = try session.loadConfiguration(unbound, resetValues: true)
    #expect(session.bank(.a).faders[0] == 0)
    #expect(session.bank(.b).encoders[3] == 0)
}

@Test func sharedParameterRulesPreserveSavedShapeAndUseZeroAnchoredLowerTies() throws {
    var p = ParameterDefinition(id: "p", name: "P", minimum: 1, maximum: 10, step: 3)
    #expect(try p.normalized(4) == 3)
    #expect(try p.normalized(9.8) == 10)
    #expect(try p.normalized(-100) == 1)
    p.minimum = -10; p.maximum = 10; p.step = 2
    #expect(try p.normalized(3) == 2)
    #expect(try p.normalized(-3) == -4)
    p.step = 0
    #expect(try p.normalized(0.37) == 0.37)
    #expect(try p.sharedDefinition.step == nil)
    p.isSwitch = true
    #expect(try p.normalized(0) == 10)
    #expect(try p.normalized(-0.01) == -10)
    let decoded = try JSONDecoder().decode(ParameterDefinition.self, from: JSONEncoder().encode(p))
    #expect(decoded == p)
    #expect(decoded.step == 0 && decoded.isSwitch)
    #expect(decoded.defaultValue == 0)
    p.minimum = 1e308; p.maximum = 1.5e308; p.defaultValue = 1e308
    #expect(try p.normalized(1.3e308) == 1.5e308)
    #expect(throws: ParameterError.self) { _ = try p.normalized(.nan) }
}

@Test func builtInPresetsKeepDefaultsAndApplyLowerTieRules() throws {
    for configuration in [SurfaceConfiguration.neutral, .audioExample] {
        try configuration.validate()
        for p in configuration.parameters {
            #expect(try p.normalized(p.defaultValue) == p.defaultValue)
        }
    }
    #expect(try SurfaceConfiguration.neutral.parameters[0].normalized(12.5) == 12)
    #expect(try SurfaceConfiguration.audioExample.parameters[0].normalized(-12.25) == -12.5)
}

@Test func legacyFilesOmitOptionalProtectionAndNewProtectionSurvivesRoundTrip() throws {
    let original = ParameterDefinition(id: "legacy", name: "Legacy")
    let bytes = try JSONEncoder().encode(original)
    let text = String(decoding: bytes, as: UTF8.self)
    #expect(!text.contains("externallyProtected"))
    #expect(try JSONDecoder().decode(ParameterDefinition.self, from: bytes).externallyProtected == nil)
    var protected = original
    protected.externallyProtected = true
    let decoded = try JSONDecoder().decode(ParameterDefinition.self, from: JSONEncoder().encode(protected))
    #expect(try decoded.sharedDefinition.externallyProtected)
    var engine = try ParameterEngine(configuration: .init(parameters: [decoded], assignments: [], version: 2))
    #expect(throws: ParameterError.agentDenied("legacy")) { try engine.set("legacy", value: 1, fromAgent: true) }
}

@Test func protectedConfigurationsUseVersionTwoAndRejectVersionOneDisguise() throws {
    var protected = ParameterDefinition(id: "p", name: "P", externallyProtected: true)
    var configuration = SurfaceConfiguration(parameters: [protected], assignments: [], version: 2)
    try configuration.validate()
    let bytes = try JSONEncoder().encode(configuration)
    let roundTrip = try JSONDecoder().decode(SurfaceConfiguration.self, from: bytes)
    #expect(roundTrip == configuration)
    // The prior application's version==1 fence rejects this even if it ignores unknown keys.
    let exported = try #require(try JSONSerialization.jsonObject(with: bytes) as? [String: Any])
    #expect(exported["version"] as? Int == 2)
    #expect(roundTrip.version != 1)
    configuration.version = 1
    #expect(throws: ParameterError.wrongDeviceOrVersion) { try configuration.validate() }
    protected.externallyProtected = false
    configuration.parameters = [protected]
    #expect(throws: ParameterError.wrongDeviceOrVersion) { try configuration.validate() }
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    let before = session.parameters.values
    #expect(throws: ParameterError.wrongDeviceOrVersion) { try session.loadConfiguration(configuration) }
    #expect(session.parameters.values == before)
    let legacy = SurfaceConfiguration.neutral
    #expect(legacy.version == 1)
    #expect(try JSONDecoder().decode(SurfaceConfiguration.self, from: JSONEncoder().encode(legacy)) == legacy)
}

@Test func invalidSharedMetadataRejectsWithoutReplacingTheCurrentConfiguration() throws {
    var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
    _ = try session.setParameter("a.Fader.1", value: 41)
    let original = session.parameters.configuration
    let values = session.parameters.values
    let invalid = [
        ParameterDefinition(id: " \t", name: "Name"),
        ParameterDefinition(id: "name", name: " \n"),
        ParameterDefinition(id: "small-step", name: "Small step", step: .leastNonzeroMagnitude),
    ]
    for definition in invalid {
        let configuration = SurfaceConfiguration(parameters: [definition], assignments: [])
        #expect(throws: ParameterError.invalidDefinition(definition.id)) { try session.loadConfiguration(configuration) }
        #expect(session.parameters.configuration == original)
        #expect(session.parameters.values == values)
    }
    for preset in [SurfaceConfiguration.neutral, .audioExample] {
        try preset.validate()
    }
}
