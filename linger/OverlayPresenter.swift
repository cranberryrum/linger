import AppKit
import Observation
import SwiftUI

// Keyboard state shared by every overlay window and the content view, so Esc can be
// held for hold-to-skip just like the mouse.
@Observable
final class OverlayInput {
    var escapeIsDown = false
    var isDismissing = false
}

final class OverlayPresenter {
    private var windows: [OverlayWindow] = []
    private var presentation: BreakPresentation?
    private var input = OverlayInput()
    private var onSkip: () -> Void = {}
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

    func present(_ presentation: BreakPresentation, onSkip: @escaping () -> Void) {
        guard self.presentation == nil else { return }
        self.presentation = presentation
        self.onSkip = onSkip
        input = OverlayInput()
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
                MainActor.assumeIsolated {
                    for window in fading { window.orderOut(nil) }
                }
            })
        }

        previousApp?.activate()
        previousApp = nil
    }

    private func screensDidChange() {
        guard presentation != nil else { return }
        for window in windows { window.orderOut(nil) }
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
        if event.keyCode == 53, !event.isARepeat { input.escapeIsDown = true }
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
