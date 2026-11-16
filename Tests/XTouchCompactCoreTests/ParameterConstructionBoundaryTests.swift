import Testing
@testable import XTouchCompactCore

@Test func parameterConstructionAdapterPreservesOriginalValidationErrorPrecedence() throws {
    var configuration = SurfaceConfiguration.neutral
    configuration.parameters.append(configuration.parameters[0])
    configuration.version = 99
    do {
        _ = try ParameterEngine(configuration: configuration)
        Issue.record("Unsupported version must fail before duplicate definitions")
    } catch let error as ParameterError {
        #expect(error == .wrongDeviceOrVersion)
    }
    configuration.version = 1
    do {
        _ = try ParameterEngine(configuration: configuration)
        Issue.record("Duplicate definitions must fail before assignment validation")
    } catch let error as ParameterError {
        #expect(error == .duplicateParameter)
    }
}

@Test func parameterConstructionAdapterRetainsDefaultAndExplicitActionBindings() throws {
    let pressed = CompactInput(control: .button(1), layer: .a, value: 127, isPressed: true)
    var defaults = try ParameterEngine()
    let defaultAction = try defaults.receive(pressed)
    #expect(defaultAction == PluginConfigurationAdapter.agentAction(1))
    let replacement = PluginConfigurationAdapter.agentAction(8)
    var injected = try ParameterEngine(actionBindings: [1: replacement])
    let explicitAction = try injected.receive(pressed)
    #expect(explicitAction == replacement)
}
