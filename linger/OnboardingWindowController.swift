import AppKit
import SwiftUI

final class OnboardingWindowController: NSWindowController, NSWindowDelegate {
    private let onFinish: () -> Void
    private var finished = false

    init(scheduler: BreakScheduler, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to linger"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: OnboardingView(scheduler: scheduler) { [weak self] in self?.close() }
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not supported")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // Finish and the red close button both end here, so the timer always starts.
    func windowWillClose(_ notification: Notification) {
        guard !finished else { return }
        finished = true
        UserDefaults.standard.set(true, forKey: DefaultsKey.hasCompletedOnboarding)
        onFinish()
    }
}
