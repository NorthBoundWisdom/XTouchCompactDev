import OutputRemoteBinding
import Testing
@testable import XTouchCompactCore

@Test func optionalBusinessPluginsAreExplicitIndependentAndVisible() throws {
    let defaultHost = try CompactPluginHost.agent()
    #expect(defaultHost.instanceIDs == ["agent"])
    #expect(defaultHost.businessPresentations.isEmpty)
    for selection in OptionalBusinessPlugin.allCases {
        var host = try CompactPluginHost.agent()
        try host.installOptional([selection], lifetimeID: "test-lifetime", at: 0)
        #expect(host.instanceIDs.count == 2)
        #expect(host.businessPresentations.map(\.id) == [selection.rawValue])
        #expect(host.manifests.last?.source == .simulation || host.manifests.first?.source == .simulation)
        var session = try CompactSession(map: FactoryStandardMap(), lightProtocol: .manual)
        #expect(try session.updateIndicators(host.feedbackIndicators).allSatisfy { message in
            if case let .controlChange(_, number, _) = message {
                return !(1 ... 9).contains(number)
            }; return true
        })
    }
    var all = try CompactPluginHost.agent()
    try all.installOptional(Set(OptionalBusinessPlugin.allCases), lifetimeID: "all-lifetime", at: 0)
    #expect(all.businessPresentations.count == 3)
    #expect(all.binding("output", as: OutputRemoteBinding.self)?.plugin.requestedEnabled == false)
    let parameters = try CompactPluginHost.referenceArmParameters()
    #expect(!parameters.isEmpty)
    let configuration = SurfaceConfiguration(parameters: parameters, assignments: [], version: 2)
    try configuration.validate()
    var engine = try ParameterEngine(configuration: configuration)
    #expect(engine.definition("arm.enabled")?.externallyProtected == true)
    #expect(throws: ParameterError.agentDenied("arm.enabled")) { try engine.set("arm.enabled", value: 1, fromAgent: true) }
    #expect(try engine.set("arm.enabled", value: 1) == 1)
}
