import AppKit
import SwiftUI

/// Shows a real break overlay for a fixed duration without touching `BreakScheduler`.
/// Used by onboarding's "See what a break looks like" preview.
final class BreakPreviewController {
    private var windows: [OverlayWindow] = []
    private var didFinish = false

    func present(duration: TimeInterval, completion: @escaping () -> Void) {
        let startedAt = Date()
        let message = BreakMessages.current.first ?? "Look far away"
        let presentation = BreakPresentation(
            message: message,
            subline: BreakMessages.subline(for: message),
            startedAt: startedAt,
            endsAt: startedAt.addingTimeInterval(duration),
            skipDifficulty: .hardcore
        )

        let cursorScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        for screen in NSScreen.screens {
            let content = screen == cursorScreen ? BreakContentView(presentation: presentation, onSkip: {}) : nil
            let window = OverlayWindow(screen: screen, content: content) { [weak self] in self?.finish(completion) }
            window.orderFrontRegardless()
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        (windows.first { $0.showsContent } ?? windows.first)?.makeKey()
        NSCursor.hide()

        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in self?.finish(completion) }
    }

    private func finish(_ completion: @escaping () -> Void) {
        guard !didFinish else { return }
        didFinish = true

        NSCursor.unhide()
        for window in windows { window.orderOut(nil) }
        windows = []
        completion()
    }
}
