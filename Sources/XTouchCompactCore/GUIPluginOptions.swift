import Foundation

public enum OptionalBusinessPlugin: String, CaseIterable, Sendable { case robot, chassis, output }

/// GUI-only launch flags. Headless services have their own command-line contracts.
public struct GUIPluginOptions: Equatable, Sendable {
    public let selection: Set<OptionalBusinessPlugin>

    public init(arguments: [String]) throws {
        var selection = Set<OptionalBusinessPlugin>()
        for plugin in OptionalBusinessPlugin.allCases {
            let retired = "--\(plugin.rawValue)-plugin"
            let replacement = "--\(plugin.rawValue)-sim"
            if arguments.contains(where: { $0 == retired || $0.hasPrefix(retired + "=") }) {
                throw InvalidOption(retired: retired, replacement: replacement)
            }
            if arguments.contains(replacement) {
                selection.insert(plugin)
            }
        }
        self.selection = selection
    }

    public struct InvalidOption: Error, LocalizedError, Equatable, Sendable {
        public let retired: String
        public let replacement: String
        public var errorDescription: String? {
            "Unsupported GUI option \(retired); use \(replacement)."
        }
    }
}
