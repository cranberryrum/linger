import AppKit
import SwiftUI

final class SettingsWindowController: NSWindowController {
    private static let frameName = "SettingsWindow"

    init(scheduler: BreakScheduler, debug: DebugActions) {
        let hosting = NSHostingController(rootView: SettingsView(scheduler: scheduler, debug: debug))
        hosting.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "linger Settings"
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName(Self.frameName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Not supported")
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
