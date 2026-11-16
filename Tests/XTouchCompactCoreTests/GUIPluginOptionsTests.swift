import Testing
@testable import XTouchCompactCore

@Test func guiOptionalModulesAreExplicitAndUseSimulationFlags() throws {
    #expect(try GUIPluginOptions(arguments: []).selection.isEmpty)
    #expect(try GUIPluginOptions(arguments: ["--robot-sim", "--chassis-sim", "--output-sim"]).selection == Set(OptionalBusinessPlugin.allCases))
    #expect(try GUIPluginOptions(arguments: ["--robot-sim", "--robot-sim"]).selection == [.robot])
}

@Test func guiRetiredFlagsFailWithReplacementEvenAlongsideNewFlags() throws {
    for plugin in OptionalBusinessPlugin.allCases {
        let old = "--\(plugin.rawValue)-plugin"
        let new = "--\(plugin.rawValue)-sim"
        for arguments in [[old], [new, old], [old + "=true"], ["--snapshot-output", old]] {
            do {
                _ = try GUIPluginOptions(arguments: arguments)
                Issue.record("Retired flag was accepted")
            } catch let error as GUIPluginOptions.InvalidOption {
                #expect(error.retired == old)
                #expect(error.replacement == new)
                #expect(error.localizedDescription.contains(new))
            }
        }
    }
}

@Test func offscreenRequiresExplicitIntegrationAndCannotHideOrdinaryStartup() throws {
    for args in [["--offscreen"], ["--startup-smoke", "--offscreen"], ["--offscreen", "--robot-sim"]] {
        #expect(throws: GUIPluginOptions.OffscreenRequiresIntegration.self) { _ = try GUIPluginOptions(arguments: args) }
    }
    #expect(try GUIPluginOptions(arguments: ["--integration-test", "--offscreen"]).selection.isEmpty)
    #expect(try GUIPluginOptions(arguments: []).selection.isEmpty)
}
