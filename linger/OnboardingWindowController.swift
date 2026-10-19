import AppKit
import Observation
import SwiftUI

// Onboarding arrives the way a break does: every screen frosts over, a soft tone plays, and the
// welcome sits in the middle of the screen with the cursor. Unlike a break it's interactive, so the
// cursor stays and keys reach the controls.
final class OnboardingWindowController {
    private let scheduler: BreakScheduler
    private let onFinish: () -> Void
    private var windows: [OnboardingOverlayWindow] = []
    private var contentWindow: OnboardingOverlayWindow?
    private let dismissal = OnboardingDismissal()
    private var finished = false
    private var observers: [any NSObjectProtocol] = []

    init(scheduler: BreakScheduler, onFinish: @escaping () -> Void) {
        self.scheduler = scheduler
        self.onFinish = onFinish

        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidChange() }
        })
        // System Settings (from a status link) or a permission prompt must not open behind the blur.
        observers.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.stepAside(true) }
        })
        observers.append(center.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard !MeetingCalendar.shared.isRequestingAccess else { return }
                self?.stepAside(false)
            }
        })
        observeCalendarPrompt()
    }

    func show() {
        if !windows.isEmpty {
            stepAside(false)
            return
        }
        buildWindows()
        NSApp.activate(ignoringOtherApps: true)
        contentWindow?.makeKeyAndOrderFront(nil)
        Sounds.play(.breakStart)

        for window in windows { window.alphaValue = 0 }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.overlayIn
            context.timingFunction = Motion.gentleCurve
            for window in windows { window.animator().alphaValue = 1 }
        }
    }

    // Finish and Esc both end here, so the timer always starts.
    private func finish() {
        guard !finished else { return }
        finished = true
        UserDefaults.standard.set(true, forKey: DefaultsKey.hasCompletedOnboarding)
        Sounds.play(.breakEnd)

        // As with a break, the words dissolve first and then the room comes back.
        dismissal.isDismissing = true
        let fading = windows
        windows = []
        contentWindow = nil
        Task {
            try? await Task.sleep(for: .seconds(Motion.reduceMotion ? 0 : 0.15))
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Motion.overlayOut
                context.timingFunction = Motion.gentleCurve
                for window in fading { window.animator().alphaValue = 0 }
            }, completionHandler: {
                MainActor.assumeIsolated {
                    for window in fading { window.close() }
                }
            })
            onFinish()
        }
    }

    // MARK: Windows

    private func buildWindows() {
        let cursorScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        for screen in NSScreen.screens {
            let window = OnboardingOverlayWindow(screen: screen)
            window.onEscape = { [weak self] in self?.finish() }
            if screen == cursorScreen { attachContent(to: window) }
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    private func attachContent(to window: OnboardingOverlayWindow) {
        let content = OnboardingView(scheduler: scheduler, dismissal: dismissal) { [weak self] in self?.finish() }
        let hosting = NSHostingView(rootView: content)
        hosting.frame = window.contentView?.bounds ?? .zero
        hosting.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(hosting)
        contentWindow = window
    }

    // Plain blur windows follow the displays; the one with the content keeps its state and moves.
    private func screensDidChange() {
        guard !windows.isEmpty, let contentWindow else { return }
        for window in windows where window !== contentWindow { window.close() }
        windows = [contentWindow]

        let screens = NSScreen.screens
        let home = screens.first { $0.frame.intersects(contentWindow.frame) } ?? NSScreen.main ?? screens.first
        if let home { contentWindow.setFrame(home.frame, display: true) }
        for screen in screens where screen != home {
            let window = OnboardingOverlayWindow(screen: screen)
            window.onEscape = { [weak self] in self?.finish() }
            window.orderFrontRegardless()
            windows.append(window)
        }
        contentWindow.makeKeyAndOrderFront(nil)
    }

    private func stepAside(_ aside: Bool) {
        guard !windows.isEmpty, !finished else { return }
        for window in windows { window.level = aside ? .normal : .screenSaver }
        if !aside {
            for window in windows { window.orderFrontRegardless() }
            contentWindow?.makeKey()
        }
    }

    private func observeCalendarPrompt() {
        withObservationTracking {
            let asking = MeetingCalendar.shared.isRequestingAccess
            stepAside(asking)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observeCalendarPrompt() }
        }
    }
}

// Lets the content dissolve before the windows fade, the same order a break ends in.
@Observable
final class OnboardingDismissal {
    var isDismissing = false
}

final class OnboardingOverlayWindow: NSWindow {
    var onEscape: (() -> Void)?

    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.addSubview(OverlayWindow.makeBackdrop(frame: root.bounds))
        contentView = root
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    // Esc ends onboarding with the defaults, as the old window's close button did.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53, !event.isARepeat { onEscape?() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }
}
