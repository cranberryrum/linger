import AppKit
import SwiftUI

final class BreakOverlayController {
    private let scheduler: BreakScheduler
    private var windows: [OverlayWindow] = []
    private var presentation: BreakPresentation?
    private var messageIndex = 0
    private var previousApp: NSRunningApplication?
    private var screenObserver: (any NSObjectProtocol)?

    init(scheduler: BreakScheduler) {
        self.scheduler = scheduler
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.screensDidChange() }
        }
        observe()
    }

    private func observe() {
        withObservationTracking {
            handle(state: scheduler.state)
        } onChange: {
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func handle(state: BreakScheduler.State) {
        switch state {
        case .onBreak(let endsAt):
            if presentation == nil { show(endsAt: endsAt) }
        default:
            if presentation != nil { hide() }
        }
    }

    // MARK: Show / hide

    private func show(endsAt: Date) {
        let messages = BreakMessages.current
        let message = messages[messageIndex % messages.count]
        messageIndex += 1

        let difficultyRaw = UserDefaults.standard.string(forKey: DefaultsKey.skipDifficulty) ?? ""
        presentation = BreakPresentation(
            message: message,
            subline: BreakMessages.subline(for: message),
            startedAt: endsAt.addingTimeInterval(-scheduler.breakDuration),
            endsAt: endsAt,
            skipDifficulty: SkipDifficulty(rawValue: difficultyRaw) ?? .balanced
        )

        previousApp = NSWorkspace.shared.frontmostApplication
        buildWindows(fadeIn: true)
        NSCursor.hide()
    }

    private func hide() {
        presentation = nil
        NSCursor.unhide()

        let fading = windows
        windows = []
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.reduceMotion ? 0 : 0.5
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            for window in fading { window.animator().alphaValue = 0 }
        }, completionHandler: {
            MainActor.assumeIsolated {
                for window in fading { window.orderOut(nil) }
            }
        })

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
            let showsContent = screen == cursorScreen
            let content = showsContent
                ? BreakContentView(presentation: presentation) { [weak self] in self?.skipIfAllowed() }
                : nil
            let window = OverlayWindow(screen: screen, content: content) { [weak self] in self?.skipIfAllowed() }
            window.alphaValue = fadeIn ? 0 : 1
            window.orderFrontRegardless()
            windows.append(window)
        }

        NSApp.activate(ignoringOtherApps: true)
        (windows.first { $0.showsContent } ?? windows.first)?.makeKey()

        if fadeIn {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = Self.reduceMotion ? 0 : 0.6
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                for window in windows { window.animator().alphaValue = 1 }
            }
        }
    }

    private func skipIfAllowed() {
        guard let presentation, presentation.canSkip(at: Date()) else { return }
        scheduler.skipBreak()
    }

    private static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

// MARK: - Window

final class OverlayWindow: NSWindow {
    let showsContent: Bool
    private let onEscape: () -> Void

    init(screen: NSScreen, content: BreakContentView?, onEscape: @escaping () -> Void) {
        self.showsContent = content != nil
        self.onEscape = onEscape
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
        if event.keyCode == 53 { onEscape() }
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
