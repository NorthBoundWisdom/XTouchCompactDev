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

    public init(_ key: String, _ arguments: String...) {
        self.key = key
        self.arguments = arguments
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
        render(message.key, arguments: message.arguments)
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
        let path = resources.path(forResource: language.rawValue, ofType: "lproj")!
        let bundle = Bundle(path: path)!
        let template = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return template }
        return String(format: template, locale: Locale(identifier: language.rawValue), arguments: arguments)
    }
}
