import Foundation
import SurfacePluginContracts

public struct DeviceProfile: Codable, Equatable, Sendable {
    public var transmitChannel = 1
    public var receiveChannel = 1
    public var ledProtocol: ButtonLightProtocol = .manual
    public var inputID: Int32?
    public var outputID: Int32?
    public init() {}
    public func validate() throws {
        guard (1 ... 16).contains(transmitChannel), (1 ... 16).contains(receiveChannel) else { throw CompactError.invalidChannel(16) }
    }
}

public struct SavedWorkspace: Codable, Equatable, Sendable {
    public var version = 1
    public var configuration: SurfaceConfiguration
    public var profile: DeviceProfile
    public var hardwareValues: HardwareValueCache?
    /// Host parameter values (software intent), keyed by parameter ID. Optional for
    /// files written before values were persisted. Restoring them never moves a motor.
    public var parameterValues: [String: Double]?
    public init(configuration: SurfaceConfiguration, profile: DeviceProfile) {
        self.configuration = configuration; self.profile = profile
    }

    public func validate() throws {
        guard version == WorkspaceMigrations.currentVersion else { throw ParameterError.wrongDeviceOrVersion }
        try configuration.validate(); try profile.validate()
        try hardwareValues?.validate()
        if let parameterValues {
            let ids = Set(configuration.parameters.map(\.id))
            guard parameterValues.allSatisfy({ ids.contains($0.key) && $0.value.isFinite }) else {
                throw ParameterError.invalidAssignment
            }
        }
    }
}

public enum StoreError: Error { case protectedCorruptFile(URL), symbolicLink, backupConflict, newerWorkspaceVersion(Int), migrationUnavailable(Int) }

/// Atomic workspace storage. Invalid originals are never rewritten implicitly.
public struct ProtectedWorkspaceStore {
    public let url: URL
    private let migrations: WorkspaceMigrations
    public init(directory: URL, migrations: WorkspaceMigrations = .init()) {
        url = directory.appendingPathComponent("workspace.json")
        self.migrations = migrations
    }

    public func load() throws -> SavedWorkspace? {
        try rejectSymlinks()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            let original = try JSONDecoder().decode(JSONValue.self, from: data)
            guard let version = original.value(for: "version")?.exactIntValue else { throw ParameterError.wrongDeviceOrVersion }
            if version > WorkspaceMigrations.currentVersion {
                throw StoreError.newerWorkspaceVersion(version)
            }
            if version < WorkspaceMigrations.currentVersion {
                _ = try protectedContentBackup(data, original: url, kind: "pre-migration")
            }
            let migrated = try migrations.migrate(original)
            let workspace = try migrated.decoded(SavedWorkspace.self)
            try workspace.validate()
            return workspace
        } catch let error as StoreError {
            // Future data is explicitly refused, never classified as a corrupt v1 file.
            if case .newerWorkspaceVersion = error {
                throw error
            }
            if case .migrationUnavailable = error {
                throw error
            }
            throw error
        } catch {
            let backup = try protectedContentBackup(data, original: url, kind: "invalid")
            throw StoreError.protectedCorruptFile(backup)
        }
    }

    public func save(_ workspace: SavedWorkspace) throws {
        try workspace.validate()
        // Explicit recovery must happen outside save; do not overwrite an invalid original.
        _ = try load()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rejectSymlinks()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(workspace).write(to: url, options: .atomic)
    }

    private func rejectSymlinks() throws {
        for target in [url, url.deletingLastPathComponent()] {
            if (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw StoreError.symbolicLink
            }
        }
    }
}

extension StoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .protectedCorruptFile(url): "Invalid workspace preserved. Fingerprint backup: \(url.path). Repair or move the original before saving again."
        case .symbolicLink: "Workspace storage refuses symbolic links."
        case .backupConflict: "Backup verification failed; original file preserved."
        case let .newerWorkspaceVersion(version): "Workspace version \(version) is newer than this application; original file preserved."
        case let .migrationUnavailable(version): "No valid migration from workspace version \(version); original file preserved."
        }
    }
}
