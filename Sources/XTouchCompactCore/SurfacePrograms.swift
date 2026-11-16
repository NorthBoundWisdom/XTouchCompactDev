import Foundation

public enum ParameterMutation: Codable, Equatable, Sendable {
    case set(String, Double), step(String, Double), toggle(String), resetGroup(String)
}

public struct SurfaceMacro: Codable, Equatable, Identifiable, Sendable {
    public let id: String
    public var name: String
    public var actions: [ParameterMutation]
    public init(id: String = UUID().uuidString, name: String, actions: [ParameterMutation]) {
        self.id = id; self.name = name; self.actions = actions
    }

    func validate(in configuration: SurfaceConfiguration) throws {
        guard !id.isEmpty, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              (1 ... 64).contains(actions.count) else { throw ParameterError.invalidAssignment }
        for action in actions {
            switch action {
            case let .set(id, value), let .step(id, value):
                guard configuration.parameters.contains(where: { $0.id == id }), value.isFinite else { throw ParameterError.invalidAssignment }
                if case .step = action, value == 0 {
                    throw ParameterError.invalidAssignment
                }
            case let .toggle(id):
                guard configuration.parameters.contains(where: { $0.id == id }) else { throw ParameterError.invalidAssignment }
            case let .resetGroup(group):
                guard configuration.parameters.contains(where: { $0.group == group }) else { throw ParameterError.invalidAssignment }
            }
        }
    }
}

public struct MacroExecution: Equatable, Sendable {
    public struct OperationResult: Identifiable, Equatable, Sendable {
        public enum Outcome: String, Sendable { case applied, deferred, withheld, rejected }
        public let id: Int
        public let outcome: Outcome
    }

    public let macroID: String
    public let name: String
    public let steps: [OperationResult]
}
