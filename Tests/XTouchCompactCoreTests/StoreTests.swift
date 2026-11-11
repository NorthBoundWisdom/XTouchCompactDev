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

@Test func symbolicLinkedWorkspaceAndDirectoryAreRejectedIncludingDanglingLinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("target")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
    let link = root.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(throws: StoreError.self) { _ = try ProtectedWorkspaceStore(directory: link).load() }
    let store = ProtectedWorkspaceStore(directory: target)
    try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: root.appendingPathComponent("missing"))
    #expect(throws: StoreError.self) { _ = try store.load() }
    #expect(throws: StoreError.self) { try store.save(SavedWorkspace(configuration: .neutral, profile: .init())) }
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("missing").path))
}
