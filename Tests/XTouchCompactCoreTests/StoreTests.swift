import Foundation
import Testing
@testable import XTouchCompactCore

@Test func workspaceRoundTripProtectsCorruptionAndOriginal() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProtectedWorkspaceStore(directory: root)
    #expect(try store.load() == nil)
    var profile = DeviceProfile(); profile.transmitChannel = 3; profile.receiveChannel = 12; profile.inputID = 867
    let workspace = SavedWorkspace(configuration: .neutral, profile: profile)
    try store.save(workspace)
    #expect(try store.load() == workspace)
    let invalid = Data("{broken}".utf8)
    try invalid.write(to: store.url)
    #expect(throws: StoreError.self) { _ = try store.load() }
    #expect(throws: StoreError.self) { try store.save(workspace) }
    #expect(try Data(contentsOf: store.url) == invalid)
    let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "backup" }
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: #require(backups.first)) == invalid)
}
