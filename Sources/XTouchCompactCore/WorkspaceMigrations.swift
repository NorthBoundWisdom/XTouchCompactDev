import Foundation
import SurfacePluginContracts

/// Explicit adjacent-version chain. No historical workspace schema predates v1 today.
/// Adding a real version requires registering and testing each adjacent transformation.
public struct WorkspaceMigrations: Sendable {
    public static let currentVersion = 1
    public struct Step: Sendable {
        public let fromVersion: Int
        public let transform: @Sendable (JSONValue) throws -> JSONValue
        public init(fromVersion: Int, transform: @escaping @Sendable (JSONValue) throws -> JSONValue) {
            self.fromVersion = fromVersion; self.transform = transform
        }
    }

    private let steps: [Step]
    public init(steps: [Step] = []) {
        self.steps = steps
    }

    public func migrate(_ original: JSONValue) throws -> JSONValue {
        var value = original
        guard var version = value.value(for: "version")?.exactIntValue, version >= 0 else { throw ParameterError.wrongDeviceOrVersion }
        guard version <= Self.currentVersion else { throw StoreError.newerWorkspaceVersion(version) }
        while version < Self.currentVersion {
            let matches = steps.filter { $0.fromVersion == version }
            guard matches.count == 1 else { throw StoreError.migrationUnavailable(version) }
            value = try matches[0].transform(value)
            guard value.value(for: "version")?.exactIntValue == version + 1 else { throw StoreError.migrationUnavailable(version) }
            version += 1
        }
        return value
    }
}

/// Stable content naming with byte-for-byte collision checking. Never follows backup symlinks.
func protectedContentBackup(_ data: Data, original: URL, kind: String) throws -> URL {
    let fingerprint = data.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
    let backup = original.appendingPathExtension("\(kind)-\(String(fingerprint, radix: 16)).backup")
    guard (try? backup.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw StoreError.symbolicLink }
    if FileManager.default.fileExists(atPath: backup.path) {
        guard try Data(contentsOf: backup) == data else { throw StoreError.backupConflict }
    } else {
        try data.write(to: backup, options: .withoutOverwriting)
    }
    guard try Data(contentsOf: backup) == data else { throw StoreError.backupConflict }
    return backup
}
