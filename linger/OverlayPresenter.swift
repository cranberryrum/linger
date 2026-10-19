import AppKit
import Observation
import SwiftUI

// Keyboard state shared by every overlay window and the content view, so Esc can be
// held for hold-to-skip just like the mouse.
@Observable
final class OverlayInput {
    static let emergencyPresses = 5
    static let emergencyWindow: TimeInterval = 3

    var escapeIsDown = false
    var isDismissing = false
    // Set once Esc has been pressed enough times in Never mode; the content shows a goodbye line.
    var isEmergencyExit = false

    // Only wired up when skipping is otherwise impossible. Deliberately never mentioned in the UI:
    // it exists so a stuck or badly timed break can always be ended, not as a skip shortcut.
    @ObservationIgnored var onEmergencyExit: (() -> Void)?
    @ObservationIgnored private var escapePresses: [Date] = []

    func escapePressed() {
        guard let onEmergencyExit, !isEmergencyExit else { return }
        let now = Date()
        escapePresses = escapePresses.filter { now.timeIntervalSince($0) < Self.emergencyWindow } + [now]
        guard escapePresses.count >= Self.emergencyPresses else { return }
        isEmergencyExit = true
        onEmergencyExit()
    }
}

final class OverlayPresenter {
    private var windows: [OverlayWindow] = []
    private var presentation: BreakPresentation?
    private var input = OverlayInput()
    private var onSkip: () -> Void = {}
    private var onEmergencyExit: () -> Void = {}
    private var previousApp: NSRunningApplication?
    private var screenObserver: (any NSObjectProtocol)?

    var isPresenting: Bool { presentation != nil }

    init() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidChange() }
        }
    }

    func present(_ presentation: BreakPresentation, onSkip: @escaping () -> Void, onEmergencyExit: @escaping () -> Void) {
        guard self.presentation == nil else { return }
        self.presentation = presentation
        self.onSkip = onSkip
        self.onEmergencyExit = onEmergencyExit
        input = OverlayInput()
        if !presentation.canSkip {
            input.onEmergencyExit = { [weak self] in self?.emergencyExit() }
        }
        previousApp = NSWorkspace.shared.frontmostApplication
        buildWindows(fadeIn: true)
        NSCursor.hide()
    }

    func dismiss() {
        guard presentation != nil else { return }
        presentation = nil
        NSCursor.unhide()

        let fading = windows
        windows = []
        input.isDismissing = true

        // Let the text start dissolving before the blur itself begins to lift.
        let lead: TimeInterval = Motion.reduceMotion ? 0 : 0.15
        Task {
            try? await Task.sleep(for: .seconds(lead))
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = Motion.overlayOut
                context.timingFunction = Motion.gentleCurve
                for window in fading { window.animator().alphaValue = 0 }
            }, completionHandler: {
                // NSApp keeps every window alive until it is closed; an orderOut alone would leave a
                // full-screen window (and its ticking content view) behind after every break.
                MainActor.assumeIsolated {
                    for window in fading { window.close() }
                }
            })
        }

        previousApp?.activate()
        previousApp = nil
    }

    // The goodbye line gets a moment to be read before the break ends.
    private func emergencyExit() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.8))
            guard let self, self.presentation != nil else { return }
            self.onEmergencyExit()
        }
    }

    private func screensDidChange() {
        guard presentation != nil else { return }
        for window in windows { window.close() }
        windows = []
        buildWindows(fadeIn: false)
    }

    private func buildWindows(fadeIn: Bool) {
        guard let presentation else { return }
        let cursorScreen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main

        for screen in NSScreen.screens {
            let content = screen == cursorScreen
                ? BreakContentView(presentation: presentation, input: input) { [weak self] in self?.onSkip() }
                : nil
            let window = OverlayWindow(screen: screen, content: content, input: input)
            window.alphaValue = fadeIn ? 0 : 1
            window.orderFrontRegardless()
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        (windows.first { $0.showsContent } ?? windows.first)?.makeKey()

        if fadeIn {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Motion.overlayIn
                context.timingFunction = Motion.gentleCurve
                for window in windows { window.animator().alphaValue = 1 }
            }
        }
    }
}

// MARK: - Window

final class OverlayWindow: NSWindow {
    let showsContent: Bool
    private let input: OverlayInput

    init(screen: NSScreen, content: BreakContentView?, input: OverlayInput) {
        self.showsContent = content != nil
        self.input = input
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)

        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        appearance = NSAppearance(named: .darkAqua)

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        root.addSubview(Self.makeBackdrop(frame: root.bounds))
        if let content {
            let hosting = NSHostingView(rootView: content)
            hosting.frame = root.bounds
            hosting.autoresizingMask = [.width, .height]
            root.addSubview(hosting)
        }
        contentView = root
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 53, !event.isARepeat else { return }
        input.escapeIsDown = true
        input.escapePressed()
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 53 { input.escapeIsDown = false }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        true
    }

    private static func makeBackdrop(frame: NSRect) -> NSView {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let flat = NSView(frame: frame)
            flat.wantsLayer = true
            flat.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.92).cgColor
            flat.autoresizingMask = [.width, .height]
            return flat
        }

        let blur = NSVisualEffectView(frame: frame)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.autoresizingMask = [.width, .height]

        let tint = NSView(frame: frame)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.1).cgColor
        tint.autoresizingMask = [.width, .height]
        blur.addSubview(tint)
        return blur
    }
}
