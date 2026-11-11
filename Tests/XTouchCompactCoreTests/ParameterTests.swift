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
    #expect(engine.values["p"] == 6)
    _ = try engine.receive(.init(control: .button(2), layer: .b, value: 127, isPressed: true))
    #expect(engine.values["p"] == 8)
    _ = try engine.receive(.init(control: .button(3), layer: .b, value: 127, isPressed: true))
    #expect(engine.values["p"] == 0)
    _ = try engine.receive(.init(control: .button(4), layer: .b, value: 127, isPressed: true))
    #expect(engine.values["p"] == 2)
    #expect(try engine.receive(.init(control: .button(5), layer: .b, value: 127, isPressed: true)) == 8)
    #expect(throws: ParameterError.self) { _ = try engine.set("p", value: .nan) }
}
