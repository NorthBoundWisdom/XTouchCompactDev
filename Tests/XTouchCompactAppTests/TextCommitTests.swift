#if os(macOS) && DEBUG
    import AppKit
    import SwiftUI
    import Testing
    @testable import XTouchCompactApp

    /// Diagnostic only: dispatch native control delegate callbacks inside an unshown
    /// non-key test window. This does not replace or pass any AX acceptance scenario.
    @Test @MainActor func textBindingUpdatesBeforeBlurAndReturnSubmitsWithoutAKeyWindow() throws {
        var text = "Initial"
        var submitted: [String] = []
        let host = NSHostingView(rootView: TextField("Name", text: Binding(get: { text }, set: { text = $0 }))
            .onSubmit { submitted.append(text) }.frame(width: 300, height: 60))
        let window = OffscreenInteractionWindow(contentRect: NSRect(x: -30000, y: -30000, width: 320, height: 90),
                                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 90)
        host.layoutSubtreeIfNeeded()
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let field = try #require(fields(host).first)
        #expect(!window.isKeyWindow && !window.isVisible && field.currentEditor() == nil)
        field.stringValue = "Edited"
        #expect(text == "Initial") // AX-style native value assignment alone sends no edit callback.
        field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
        #expect(text == "Edited") // The binding changes before any blur/end-edit notification.
        #expect(submitted.isEmpty)
        let action = try #require(field.action)
        #expect(field.sendAction(action, to: field.target))
        #expect(submitted == ["Edited"])
        #expect(!window.isKeyWindow && !window.isVisible)
        window.contentView = nil
    }

    @Test @MainActor func libraryReturnUsesTheSaveIntentAndRejectsBlankNames() throws {
        let model = ConsoleModel(startsMIDI: false, isolated: true)
        var saved: [String] = []
        var intents = model.panelIntents
        intents.saveLibraryConfiguration = { saved.append($0) }
        let defaults = try #require(UserDefaults(suiteName: "XTouch.TextCommit." + UUID().uuidString))
        let host = NSHostingView(rootView: ConfigurationLibraryView(snapshot: model.panelSnapshot, intents: intents)
            .environmentObject(LanguageSettings(defaults: defaults)).frame(width: 580, height: 500))
        let window = OffscreenInteractionWindow(contentRect: NSRect(x: -30000, y: -30000, width: 580, height: 500),
                                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 580, height: 500)
        host.layoutSubtreeIfNeeded()
        func fields(_ view: NSView) -> [NSTextField] {
            (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(fields)
        }
        let field = try #require(fields(host).first)
        let action = try #require(field.action)
        for text in ["Return saved", "   "] {
            field.stringValue = text
            field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
            #expect(field.sendAction(action, to: field.target))
        }
        #expect(saved == ["Return saved"])
        #expect(!window.isKeyWindow && !window.isVisible && field.currentEditor() == nil)
        window.contentView = nil
    }

#endif
