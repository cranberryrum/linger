import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private static let frameName = "SettingsWindow"

    var onClose: (() -> Void)?

    init(scheduler: BreakScheduler, debug: DebugActions) {
        let hosting = NSHostingController(rootView: SettingsView(scheduler: scheduler, debug: debug))

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.collectionBehavior = [.fullScreenNone]
        window.toolbarStyle = .unified
        window.title = "linger"
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName(Self.frameName) {
            window.center()
        }
        let contentSize = NSSize(width: 700, height: 480)
        window.setContentSize(contentSize)
        window.contentMinSize = contentSize
        window.contentMaxSize = contentSize
        window.setFrameAutosaveName(Self.frameName)
        super.init(window: window)
        window.delegate = self
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        onClose?()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not supported")
    }

    func show() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
