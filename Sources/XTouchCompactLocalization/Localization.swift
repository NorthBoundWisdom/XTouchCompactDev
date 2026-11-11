import Foundation

public enum AppLanguage: String, CaseIterable, Sendable {
    case system, english = "en", simplifiedChinese = "zh-Hans", traditionalChinese = "zh-Hant"

    public init(storedValue: String?) {
        self = storedValue.flatMap(Self.init(rawValue:)) ?? .system
    }

    public func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        guard self == .system else { return self }
        for language in preferredLanguages {
            let parts = language.lowercased().replacingOccurrences(of: "_", with: "-").split(separator: "-")
            if parts.first == "en" {
                return .english
            }
            if parts.first == "zh" {
                if parts.contains("hant") {
                    return .traditionalChinese
                }
                if parts.contains("hans") {
                    return .simplifiedChinese
                }
                return parts.contains(where: { ["tw", "hk", "mo"].contains($0) })
                    ? .traditionalChinese : .simplifiedChinese
            }
        }
        return .english
    }
}

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

public struct Localizer: Sendable {
    public let language: AppLanguage
    public init(language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) {
        self.language = language.resolved(preferredLanguages: preferredLanguages)
    }

    public func text(_ key: String, _ arguments: String...) -> String {
        render(key, arguments: arguments)
    }

    public func text(_ message: LocalizedMessage) -> String {
        let arguments = message.arguments.enumerated().map { index, value in
            message.localizedArgumentIndices.contains(index) ? render(value, arguments: []) : value
        }
        return render(message.key, arguments: arguments)
    }

    private func render(_ key: String, arguments: [String]) -> String {
        let resourceName = "XTouchCompactDev_XTouchCompactLocalization"
        let resources: Bundle = if let url = Bundle.main.resourceURL?.appendingPathComponent(resourceName + ".bundle"),
                                   let packaged = Bundle(url: url)
        {
            packaged
        } else {
            .module
        }
        // SwiftPM's native build lowercases localization directories (`zh-hans.lproj`), and
        // bundle lookup is case-sensitive there. Keys are the English source text, so a
        // missing catalog degrades to English instead of crashing.
        let path = resources.path(forResource: language.rawValue, ofType: "lproj")
            ?? resources.path(forResource: language.rawValue.lowercased(), ofType: "lproj")
        let template = path.flatMap(Bundle.init(path:))?.localizedString(forKey: key, value: key, table: nil) ?? key
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: Locale(identifier: language.rawValue), arguments: arguments)
    }
}
