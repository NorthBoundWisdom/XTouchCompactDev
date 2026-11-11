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
