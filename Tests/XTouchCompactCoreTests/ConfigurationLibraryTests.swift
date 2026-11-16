import Foundation
import SurfacePluginContracts
import Testing
@testable import XTouchCompactCore

@Test func namedConfigurationLibraryRoundTripsOnlyConfigurationAndProtectsInvalidOriginals() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConfigurationLibraryStore(directory: root)
    let entry = SavedConfiguration(name: "Studio", configuration: .neutral)
    try store.save([entry])
    #expect(try store.load() == [entry])
    let json = try JSONDecoder().decode(JSONValue.self, from: Data(contentsOf: store.url))
    #expect(try Set(#require(json.arrayValue?.first?.objectValue).keys) == ["id", "name", "configuration"])
    #expect(throws: ConfigurationLibraryError.self) { try store.save([entry, entry]) }
    var foreign = SurfaceConfiguration.neutral; foreign.device = "BCR2000"
    #expect(throws: ParameterError.self) { try store.save([.init(name: "Foreign", configuration: foreign)]) }
    let damaged = Data("corrupt".utf8)
    try damaged.write(to: store.url)
    #expect(throws: StoreError.self) { _ = try store.load() }
    #expect(throws: StoreError.self) { try store.save([]) }
    #expect(try Data(contentsOf: store.url) == damaged)
    let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.pathExtension == "backup" }
    #expect(backups.count == 1)
    #expect(try Data(contentsOf: #require(backups.first)) == damaged)
}

@Test func workspaceMigrationsBackUpBeforeTransformPreserveOriginalAndRefuseNewerFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let workspace = SavedWorkspace(configuration: .neutral, profile: .init())
    var raw = try #require(try JSONValue.encoded(workspace).objectValue)
    raw["version"] = .number(0)
    let original = try JSONEncoder().encode(JSONValue.object(raw))
    let file = root.appendingPathComponent("workspace.json")
    try original.write(to: file)
    let migration = WorkspaceMigrations(steps: [.init(fromVersion: 0) { value in
        let backups = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        #expect(backups.contains { $0.lastPathComponent.contains("pre-migration") })
        var next = value.objectValue!; next["version"] = .number(1)
        return .object(next)
    }])
    let store = ProtectedWorkspaceStore(directory: root, migrations: migration)
    #expect(try store.load() == workspace)
    #expect(try Data(contentsOf: file) == original) // In-memory migration; save is explicit.
    #expect(throws: StoreError.self) { _ = try ProtectedWorkspaceStore(directory: root).load() }
    #expect(try Data(contentsOf: file) == original)
    let broken = ProtectedWorkspaceStore(directory: root, migrations: .init(steps: [.init(fromVersion: 0) { _ in throw ParameterError.invalidAssignment }]))
    #expect(throws: StoreError.self) { _ = try broken.load() }
    #expect(try Data(contentsOf: file) == original)
    try store.save(workspace)
    #expect(try store.load() == workspace)
    raw["version"] = .number(99)
    let future = try JSONEncoder().encode(JSONValue.object(raw)); try future.write(to: file)
    #expect(throws: StoreError.self) { _ = try store.load() }
    #expect(throws: StoreError.self) { try store.save(workspace) }
    #expect(try Data(contentsOf: file) == future)
}

@Test func workspaceBackupConflictsAndSymlinksNeverOverwriteOriginalOrOutsideFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ProtectedWorkspaceStore(directory: root)
    let original = Data("broken".utf8); try original.write(to: store.url)
    #expect(throws: StoreError.self) { _ = try store.load() }
    let backup = try #require(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first { $0.pathExtension == "backup" })
    try Data("conflict".utf8).write(to: backup)
    #expect(throws: StoreError.self) { _ = try store.load() }
    #expect(try Data(contentsOf: store.url) == original)
    try FileManager.default.removeItem(at: backup)
    let outside = root.appendingPathComponent("outside"); try Data("keep".utf8).write(to: outside)
    try FileManager.default.createSymbolicLink(at: backup, withDestinationURL: outside)
    #expect(throws: StoreError.self) { _ = try store.load() }
    #expect(try Data(contentsOf: outside) == Data("keep".utf8))
}
