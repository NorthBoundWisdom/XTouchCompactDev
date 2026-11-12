import Foundation

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
        guard version == 1 else { throw ParameterError.wrongDeviceOrVersion }
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

public enum StoreError: Error { case protectedCorruptFile(URL), symbolicLink }

/// Atomic workspace storage. Invalid originals are never rewritten implicitly.
public struct ProtectedWorkspaceStore {
    public let url: URL
    public init(directory: URL) {
        url = directory.appendingPathComponent("workspace.json")
    }

    public func load() throws -> SavedWorkspace? {
        try rejectSymlinks()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        do {
            let workspace = try JSONDecoder().decode(SavedWorkspace.self, from: data)
            try workspace.validate()
            return workspace
        } catch {
            // FNV-1a is a stable content fingerprint, not a security hash.
            let fingerprint = data.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
            let backup = url.appendingPathExtension("invalid-\(String(fingerprint, radix: 16)).backup")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try data.write(to: backup, options: .withoutOverwriting)
            }
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
        }
    }
}
