import Foundation
import Testing
@testable import XTouchCompactCore

@Test func armPreviewRequiresDeclaredDegreeParametersAndPreservesUnknownOptionals() throws {
    var parameters = try CompactPluginHost.referenceArmParameters()
    var config = SurfaceConfiguration(parameters: parameters, assignments: [], version: 2)
    let values = Dictionary(uniqueKeysWithValues: parameters.map { ($0.id, $0.defaultValue) })
    let pose = try #require(ArmPreviewSnapshot(configuration: config, values: values))
    #expect(pose.joints == [0, 30, -60, -20] && pose.enabled == false)
    #expect(pose.sidePoints.count == 4)
    #expect(pose.sidePoints.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    #expect(pose.topDirection == .init(x: 0, y: 1))
    parameters.removeAll { ["arm.enabled", "arm.speed", "arm.gripper"].contains($0.id) }
    config.parameters = parameters
    let missing = try #require(ArmPreviewSnapshot(configuration: config, values: values))
    #expect(missing.enabled == nil && missing.gripper == nil && missing.speed == nil)
    config.parameters[0].unit = "rad"
    #expect(ArmPreviewSnapshot(configuration: config, values: values) == nil)
    #expect(ArmPreviewSnapshot(configuration: .neutral, values: [:]) == nil)
    #expect(ArmPreviewSnapshot.radians(720) == 0)
}

@Test func optionalPanelChoiceIsSeparateVersionedAndProtected() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = WorkspacePanelStore(directory: root)
    #expect(try !store.load().armVisible)
    var settings = WorkspacePanelSettings(); settings.setArmVisible(true)
    try store.save(settings)
    #expect(try store.load().armVisible)
    for enabled in [["arm", "arm"], ["output"], ["values"]] {
        var invalid = settings; invalid.enabled = enabled
        #expect(throws: ParameterError.self) { try invalid.validate() }
    }
    let original = Data(#"{"version":99,"enabled":["arm"]}"#.utf8)
    try original.write(to: store.url)
    #expect(throws: StoreError.self) { try store.save(settings) }
    #expect(try Data(contentsOf: store.url) == original)
}
