#if os(macOS)
import Foundation
import Testing
@testable import XTouchCompactApp
import XTouchCompactLocalization
import XTouchCompactCore

@Test @MainActor func languageSelectionPersistsAcrossLaunches() throws {
    let name = "XTouchCompactDev.language-tests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defer { defaults.removePersistentDomain(forName: name) }
    let settings = LanguageSettings(defaults: defaults)
    #expect(settings.selection == .system)
    settings.selection = .traditionalChinese
    #expect(settings.localizer.text("Settings") == "設定")
    #expect(LanguageSettings(defaults: defaults).selection == .traditionalChinese)
    settings.selection = .english
    #expect(settings.localizer.text("Settings") == "Settings")
    settings.selection = .system
    #expect(LanguageSettings(defaults: defaults).selection == .system)
}
@Test @MainActor func localizedPanelPreservesMockStateAndRawMIDI() {
    let model = ConsoleModel(startsMIDI: false)
    model.touchFader(1, isTouched: true)
    model.moveFader(1, value: 42)
    model.faderChanged(1, value: 90)
    let before = model.panelSnapshot
    let messages = model.logs
    let english = Localizer(language: .english)
    let chinese = Localizer(language: .traditionalChinese)
    #expect(CompactControl.fader(1).localizedName(using: english) == "Fader 1")
    #expect(CompactControl.fader(1).localizedName(using: chinese) == "推桿 1")
    #expect(PanelLayout.buttonName(39, using: english) == "Transport · Play")
    #expect(PanelLayout.buttonName(39, using: chinese) == "走帶 · 播放")
    #expect(messages.map { english.text($0) }.contains("IN CC ch1 #1=42 [MOCK]"))
    #expect(messages.map { chinese.text($0) }.contains("輸入 CC ch1 #1=42 [模擬]"))
    #expect(model.panelSnapshot == before)
    #expect(model.panelSnapshot.fader(1)?.isTouched == true)
    #expect(model.panelSnapshot.fader(1)?.isMotorPending == true)
}
#endif
