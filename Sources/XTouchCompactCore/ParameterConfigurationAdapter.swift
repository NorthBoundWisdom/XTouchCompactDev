import Foundation
import SurfacePluginContracts

public extension ParameterEngine {
    init(configuration: SurfaceConfiguration = .neutral, actionBindings: [Int: ActionReference] = PluginConfigurationAdapter.agentActions) throws {
        try configuration.validate()
        try self.init(validatedConfiguration: .init(value: configuration), actionBindings: actionBindings)
    }
}

public extension SurfaceConfiguration {
    static var neutral: Self {
        var parameters: [ParameterDefinition] = []
        var assignments: [ControlAssignment] = []
        for layer in CompactLayer.allCases {
            for (kind, count) in [("Fader", 9), ("Encoder", 16)] {
                for index in 1 ... count {
                    let id = "\(layer.rawValue).\(kind).\(index)"
                    parameters.append(ParameterDefinition(id: id, name: "\(kind) \(index)", group: "Layer \(layer.rawValue.uppercased())"))
                    assignments.append(ControlAssignment(control: kind == "Fader" ? .fader(index) : .encoder(index), layer: layer, action: .parameter(id)))
                }
            }
            for slot in 1 ... 8 {
                assignments.append(ControlAssignment(control: .button(slot), layer: layer, action: .agent(slot)))
            }
        }
        return Self(parameters: parameters, assignments: assignments)
    }
}

public extension SurfaceConfiguration {
    /// An explicitly loaded example; never selected automatically for connected hardware.
    static var audioExample: Self {
        var configuration = neutral
        for index in configuration.parameters.indices {
            configuration.parameters[index].group = "Audio"
            configuration.parameters[index].unit = "dB"
            configuration.parameters[index].minimum = -60
            configuration.parameters[index].maximum = 6
            configuration.parameters[index].defaultValue = -60
            configuration.parameters[index].step = 0.5
        }
        return configuration
    }
}

extension ParameterError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .wrongDeviceOrVersion: "This configuration is not a supported X-TOUCH COMPACT version 1 or 2 configuration."
        case .duplicateParameter: "Parameter IDs must be unique."
        case let .invalidDefinition(id): "Invalid parameter definition: \(id). Check its range and step."
        case .invalidAssignment: "Invalid or duplicate control assignment. Check control range and Agent slot."
        case let .unknownParameter(id): "Unknown parameter: \(id)."
        case let .agentDenied(id): "Agent writes are disabled for parameter: \(id)."
        case let .invalidLink(id): "Invalid parameter link: \(id). Leader and members must exist, differ, and not chain."
        case let .invalidScene(id): "Invalid scene: \(id). Scenes need a name and finite values for existing parameters."
        }
    }
}
