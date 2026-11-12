import Foundation
import Testing
@testable import XTouchCompactLocalization

@Test func systemLanguageResolution() {
    #expect(AppLanguage(storedValue: nil) == .system)
    #expect(AppLanguage(storedValue: "obsolete") == .system)
    #expect(AppLanguage(storedValue: "zh-Hant") == .traditionalChinese)
    let cases: [([String], AppLanguage)] = [
        (["en-GB", "zh-TW"], .english), (["zh-CN"], .simplifiedChinese),
        (["zh_SG"], .simplifiedChinese), (["zh-TW"], .traditionalChinese),
        (["zh-HK"], .traditionalChinese), (["zh-MO"], .traditionalChinese),
        (["zh-Hans-HK"], .simplifiedChinese), (["zh-Hant-CN"], .traditionalChinese),
        (["fr-FR", "zh-TW"], .traditionalChinese), (["ja-JP"], .english), ([], .english),
    ]
    for (preferences, expected) in cases {
        #expect(AppLanguage.system.resolved(preferredLanguages: preferences) == expected)
    }
    #expect(AppLanguage.english.resolved(preferredLanguages: ["zh-CN"]) == .english)
}

@Test func translationAndExistingMessagesFollowSelection() {
    let message = LocalizedMessage("OUT %@ [MOCK]", "CC 12 127")
    #expect(Localizer(language: .english).text(message) == "OUT CC 12 127 [MOCK]")
    #expect(Localizer(language: .simplifiedChinese).text(message) == "输出 CC 12 127 [模拟]")
    #expect(Localizer(language: .traditionalChinese).text(message) == "輸出 CC 12 127 [模擬]")
    #expect(Localizer(language: .traditionalChinese).text("Transmit channel: %@", "16") == "傳送通道：16")
    #expect(Localizer(language: .system, preferredLanguages: ["zh-TW"]).text("Settings") == "設定")
}

@Test func allCatalogsHaveMatchingKeysAndFormatArguments() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/XTouchCompactLocalization/Resources")
    func catalog(_ language: String) throws -> [String: String] {
        let data = try Data(contentsOf: root.appendingPathComponent("\(language).lproj/Localizable.strings"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
    }
    let english = try catalog("en")
    for language in ["zh-Hans", "zh-Hant"] {
        let translated = try catalog(language)
        #expect(Set(english.keys) == Set(translated.keys))
        for (key, value) in translated {
            #expect(!value.isEmpty)
            #expect(key.components(separatedBy: "%@").count == value.components(separatedBy: "%@").count)
            #expect(try Localizer(language: #require(AppLanguage(rawValue: language))).text(key) == value)
        }
    }
}

/// Every literal key the app passes to `l.text(…)` must exist in the English catalog. A key
/// that is missing (or mangled, e.g. by an escape the .strings parser does not understand)
/// silently falls back to the source text in every language.
@Test func everyLiteralKeyUsedByTheAppExistsInTheCatalog() throws {
    let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let catalogURL = repository.appendingPathComponent("Sources/XTouchCompactLocalization/Resources/en.lproj/Localizable.strings")
    let catalog = try #require(PropertyListSerialization.propertyList(from: Data(contentsOf: catalogURL), format: nil) as? [String: String])
    // No key may contain a leftover escape fragment.
    #expect(!catalog.keys.contains { $0.contains("u2026") || $0.contains("\\u") })
    let sources = repository.appendingPathComponent("Sources/XTouchCompactApp")
    let pattern = try NSRegularExpression(pattern: #"(?:\bl|localizer)\.text\(\s*"((?:[^"\\]|\\.)*)""#)
    var missing: Set<String> = []
    for file in try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil) where file.pathExtension == "swift" {
        let text = try String(contentsOf: file, encoding: .utf8)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let literal = try String(text[#require(Range(match.range(at: 1), in: text))])
            // Skip interpolated keys; unescape the rest.
            guard !literal.contains("\\(") else { continue }
            let key = literal.replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
            if catalog[key] == nil {
                missing.insert(key)
            }
        }
    }
    #expect(missing.isEmpty, "Keys used by the app but absent from the catalog: \(missing.sorted())")
}
