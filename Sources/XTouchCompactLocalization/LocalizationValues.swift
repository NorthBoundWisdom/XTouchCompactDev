import Foundation

/// Resolve at display time so existing logs and errors follow language changes.
public struct LocalizedMessage: Equatable, Sendable {
    public let key: String
    public let arguments: [String]
    public let localizedArgumentIndices: Set<Int>

    public init(key: String, arguments: [String], localizedArgumentIndices: Set<Int> = []) {
        self.key = key; self.arguments = arguments; self.localizedArgumentIndices = localizedArgumentIndices
    }

    public init(_ key: String, _ arguments: String...) {
        self.key = key
        self.arguments = arguments
        localizedArgumentIndices = []
    }
}
