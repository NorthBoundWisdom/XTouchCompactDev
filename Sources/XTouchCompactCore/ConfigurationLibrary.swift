import Foundation

public struct SavedConfiguration: Codable, Identifiable, Equatable, Sendable {
    public let id: UUID
    public let name: String
    public let configuration: SurfaceConfiguration
    public init(id: UUID = UUID(), name: String, configuration: SurfaceConfiguration) {
        self.id = id; self.name = name; self.configuration = configuration
    }
}

public enum ConfigurationLibraryError: Error { case invalidName, duplicateName, invalidEntries, tooLarge }

/// Configuration only: no profile, current parameter values, connection or permissions.
public struct ConfigurationLibraryStore: Sendable {
    public let url: URL
    public init(directory: URL) {
        url = directory.appendingPathComponent("configuration-library.json")
    }

    public static let maximumBytes = 4 * 1024 * 1024

    public static func validate(_ entries: [SavedConfiguration]) throws {
        guard Set(entries.map(\.id)).count == entries.count, Set(entries.map(\.name)).count == entries.count else { throw ConfigurationLibraryError.invalidEntries }
        for entry in entries {
            guard !entry.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ConfigurationLibraryError.invalidName }
            try entry.configuration.validate()
        }
    }

    public func load() throws -> [SavedConfiguration] {
        try rejectSymlinks()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        do {
            guard data.count <= Self.maximumBytes else { throw ConfigurationLibraryError.tooLarge }
            let entries = try JSONDecoder().decode([SavedConfiguration].self, from: data)
            try Self.validate(entries)
            return entries
        } catch {
            let backup = try protectedContentBackup(data, original: url, kind: "invalid")
            throw StoreError.protectedCorruptFile(backup)
        }
    }

    public func save(_ entries: [SavedConfiguration]) throws {
        try Self.validate(entries)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        guard data.count <= Self.maximumBytes else { throw ConfigurationLibraryError.tooLarge }
        _ = try load() // A bad original remains protected, even after a previously successful load.
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rejectSymlinks()
        try data.write(to: url, options: .atomic)
    }

    private func rejectSymlinks() throws {
        for target in [url, url.deletingLastPathComponent()] {
            guard (try? target.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw StoreError.symbolicLink }
        }
    }
}

public struct ConfigurationLibraryRequest: Equatable, Sendable {
    public enum Kind: Sendable { case load, delete }
    public let id: UUID
    public let name: String
    public let kind: Kind
    public init(id: UUID, name: String, kind: Kind) {
        self.id = id; self.name = name; self.kind = kind
    }
}
