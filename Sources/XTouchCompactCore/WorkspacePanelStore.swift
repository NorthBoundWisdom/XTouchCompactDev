import Foundation

/// Presentation choices are separate from workspace configuration, values and hardware profiles.
public struct WorkspacePanelStore: Sendable {
    public let url: URL
    public init(directory: URL) {
        url = directory.appendingPathComponent("workspace-panels.json")
    }

    public func load() throws -> WorkspacePanelSettings {
        try rejectSymlinks()
        guard FileManager.default.fileExists(atPath: url.path) else { return .init() }
        let data = try Data(contentsOf: url)
        do {
            guard data.count <= 4096 else { throw ParameterError.invalidAssignment }
            let value = try JSONDecoder().decode(WorkspacePanelSettings.self, from: data)
            try value.validate()
            return value
        } catch {
            let backup = try protectedContentBackup(data, original: url, kind: "invalid")
            throw StoreError.protectedCorruptFile(backup)
        }
    }

    public func save(_ settings: WorkspacePanelSettings) throws {
        try settings.validate(); _ = try load()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try rejectSymlinks()
        try JSONEncoder().encode(settings).write(to: url, options: .atomic)
    }

    private func rejectSymlinks() throws {
        for value in [url, url.deletingLastPathComponent()] {
            guard (try? value.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw StoreError.symbolicLink }
        }
    }
}
