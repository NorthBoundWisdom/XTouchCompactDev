#if os(macOS) && DEBUG
    import AppKit
    import ObjectiveC.runtime

    /// Only the explicitly isolated command installs these process-local overrides.
    @MainActor enum OffscreenPresentation {
        private static var observers: [NSObjectProtocol] = []
        private(set) static var suppressedActivations = 0
        static func install() throws {
            NSApp.setActivationPolicy(.prohibited)
            guard let type = object_getClass(NSApp) else { throw CocoaError(.featureUnsupported) }
            for (name, block) in [
                ("activate", imp_implementationWithBlock({ (_: AnyObject) in suppressedActivations += 1 } as @convention(block) (AnyObject) -> Void)),
                ("activateIgnoringOtherApps:", imp_implementationWithBlock({ (_: AnyObject, _: Bool) in suppressedActivations += 1 } as @convention(block) (AnyObject, Bool) -> Void)),
            ] {
                let selector = NSSelectorFromString(name)
                guard let method = class_getInstanceMethod(type, selector) else { throw CocoaError(.featureUnsupported) }
                class_replaceMethod(type, selector, block, method_getTypeEncoding(method))
            }
            for name in [NSApplication.didUpdateNotification, NSWindow.didUpdateNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.willBeginSheetNotification]
            {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated {
                        for window in NSApp.windows {
                            conceal(window)
                        }
                    }
                })
            }
        }

        static func conceal(_ window: NSWindow) {
            if window.alphaValue != 0 {
                window.alphaValue = 0
            }
            if !window.ignoresMouseEvents {
                window.ignoresMouseEvents = true
            }
            if window.isRestorable {
                window.isRestorable = false
            }
        }
    }

    @MainActor final class OffscreenInteractionWindow: NSPanel {
        override var canBecomeKey: Bool {
            false
        }

        override var canBecomeMain: Bool {
            false
        }
    }
#endif
