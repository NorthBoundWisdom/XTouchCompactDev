#if os(macOS)
    import AppKit
    import SwiftUI

    /// Observes the real scene's first AppKit display/update cycle, without a timer.
    struct StartupFrameProbe: NSViewRepresentable {
        let onPresented: @MainActor () -> Void
        func makeNSView(context _: Context) -> StartupFrameView {
            StartupFrameView(onPresented: onPresented)
        }

        func updateNSView(_: StartupFrameView, context _: Context) {}
    }

    @MainActor final class StartupFrameView: NSView {
        private let onPresented: @MainActor () -> Void
        private var observer: NSObjectProtocol?
        private var hasDrawn = false
        private var completed = false

        init(onPresented: @escaping @MainActor () -> Void) {
            self.onPresented = onPresented
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) is unavailable")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            guard let window else { return }
            window.isRestorable = false
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didUpdate() }
            }
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard !hasDrawn, window != nil, !bounds.isEmpty else { return }
            hasDrawn = true
            // Schedule a window update after drawing returns. didUpdate is the
            // completion signal, rather than appearance or an elapsed sleep.
            DispatchQueue.main.async { [weak self] in self?.window?.update() }
        }

        private func didUpdate() {
            guard !completed, hasDrawn, let window, window.isVisible,
                  window.windowNumber > 0, !bounds.isEmpty else { return }
            completed = true
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
            observer = nil
            DispatchQueue.main.async { [onPresented] in onPresented() }
        }

        isolated deinit {
            if let observer {
                NotificationCenter.default.removeObserver(observer)
            }
        }
    }
#endif
