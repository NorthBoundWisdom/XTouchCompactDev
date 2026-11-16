import Foundation

public extension SurfaceConfiguration {
    func validate() throws {
        guard version == 1 || version == 2, device == "X-TOUCH COMPACT",
              version != 1 || parameters.allSatisfy({ $0.externallyProtected == nil }) else { throw ParameterError.wrongDeviceOrVersion }
        guard Set(parameters.map(\.id)).count == parameters.count else { throw ParameterError.duplicateParameter }
        let ids = Set(parameters.map(\.id))
        guard Set((macros ?? []).map(\.id)).count == (macros ?? []).count else { throw ParameterError.invalidAssignment }
        for macro in macros ?? [] {
            try macro.validate(in: self)
        }
        try validateLinksAndScenes(ids: ids)
        var keys = Set<String>()
        let map = try FactoryStandardMap()
        for parameter in parameters {
            guard !parameter.id.isEmpty, !parameter.name.isEmpty else { throw ParameterError.invalidDefinition(parameter.id) }
            _ = try parameter.normalized(parameter.defaultValue)
        }
        for assignment in assignments {
            guard map.inputAddress(for: assignment.control, layer: assignment.layer) != nil,
                  keys.insert("\(assignment.layer.rawValue):\(assignment.control)").inserted else { throw ParameterError.invalidAssignment }
            switch assignment.control {
            case .fader, .encoder, .expression:
                guard case .parameter = assignment.action else { throw ParameterError.invalidAssignment }
            default: break
            }
            switch assignment.action {
            case let .runMacro(id):
                guard macros?.contains(where: { $0.id == id }) == true else { throw ParameterError.invalidAssignment }
            case let .agent(slot): guard (1 ... 8).contains(slot) else { throw ParameterError.invalidAssignment }
            case let .resetGroup(group):
                guard parameters.contains(where: { $0.group == group }) else { throw ParameterError.invalidAssignment }
            case let .parameter(id): guard ids.contains(id) else { throw ParameterError.unknownParameter(id) }
            case let .step(id, value), let .set(id, value):
                guard ids.contains(id), value.isFinite else { throw ParameterError.invalidAssignment }
            case let .cycle(id, values):
                guard ids.contains(id), !values.isEmpty, values.allSatisfy(\.isFinite) else { throw ParameterError.invalidAssignment }
            }
        }
    }
}

extension SurfaceConfiguration {
    func validateLinksAndScenes(ids: Set<String>) throws {
        var linkIDs = Set<String>()
        var followers = Set<String>()
        for link in links ?? [] {
            guard !link.id.isEmpty, linkIDs.insert(link.id).inserted,
                  !link.name.trimmingCharacters(in: .whitespaces).isEmpty,
                  ids.contains(link.leader), !link.members.isEmpty,
                  Set(link.members).count == link.members.count,
                  link.members.allSatisfy({ ids.contains($0) && $0 != link.leader })
            else { throw ParameterError.invalidLink(link.id) }
            // One leader per follower and no follower leads: links never chain or loop.
            for member in link.members {
                guard followers.insert(member).inserted else { throw ParameterError.invalidLink(link.id) }
            }
        }
        let leaders = Set((links ?? []).map(\.leader))
        guard leaders.isDisjoint(with: followers) else { throw ParameterError.invalidLink("chain") }
        var sceneIDs = Set<String>()
        for scene in scenes ?? [] {
            guard !scene.id.isEmpty, sceneIDs.insert(scene.id).inserted,
                  !scene.name.trimmingCharacters(in: .whitespaces).isEmpty,
                  scene.values.allSatisfy({ ids.contains($0.key) && $0.value.isFinite })
            else { throw ParameterError.invalidScene(scene.id) }
        }
    }
}
