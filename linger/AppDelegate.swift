import AppKit
import Carbon.HIToolbox

@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let shared = AppDelegate()

    static func main() {
        DefaultsKey.registerDefaults()
        let app = NSApplication.shared
        app.delegate = shared
        app.run()
    }

    let scheduler = BreakScheduler()
    private var statusItemController: StatusItemController?
    private var overlayController: BreakOverlayController?
    private var headsUpController: HeadsUpPanelController?
    private var cursorCountdown: CursorCountdownController?
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var hotKey: GlobalHotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        statusItemController = StatusItemController(scheduler: scheduler) { [weak self] in self?.openSettings() }
        overlayController = BreakOverlayController(scheduler: scheduler)
        headsUpController = HeadsUpPanelController(scheduler: scheduler)
        cursorCountdown = CursorCountdownController(scheduler: scheduler)
        scheduler.onHeadsUp = { [weak self] in self?.headsUpController?.show() }
        scheduler.onFinalCountdown = { Sounds.play(.finalCountdown) }
        hotKey = GlobalHotKey(keyCode: kVK_ANSI_L, modifiers: controlKey | optionKey | cmdKey) { [scheduler] in
            scheduler.startBreakNow()
        }
        scheduler.onBreakCompleted = { Sounds.play(.breakEnd) }

        if UserDefaults.standard.bool(forKey: DefaultsKey.hasCompletedOnboarding) {
            scheduler.start()
        } else {
            showOnboarding()
        }
    }

    private func showOnboarding() {
        if let onboardingWindowController {
            onboardingWindowController.show()
            return
        }
        // Re-running the welcome flow from Settings must not restart a timer that is already going.
        let firstRun = !scheduler.isRunning
        onboardingWindowController = OnboardingWindowController(scheduler: scheduler) { [weak self] in
            self?.onboardingWindowController = nil
            guard firstRun else { return }
            self?.scheduler.start()
            self?.statusItemController?.showRunningHint()
        }
        onboardingWindowController?.show()
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            let debug = DebugActions(
                showHeadsUp: { [weak self] in self?.headsUpController?.show() },
                showRunningHint: { [weak self] in self?.statusItemController?.showRunningHint() },
                showOnboarding: { [weak self] in self?.showOnboarding() }
            )
            let controller = SettingsWindowController(scheduler: scheduler, debug: debug)
            // A closed-but-alive Settings window would keep its countdown views updating every second.
            // Dropping it after the close finishes tears the SwiftUI tree down; the frame is autosaved.
            controller.onClose = { [weak self] in
                Task { @MainActor [weak self] in self?.settingsWindowController = nil }
            }
            settingsWindowController = controller
        }
        settingsWindowController?.show()
    }

    // The menu bar itself is never shown (LSUIElement), but a main menu is what routes
    // ⌘C/⌘V/⌘W/⌘Q key equivalents to text fields and windows.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit linger", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: "linger", action: nil, keyEquivalent: "").submenu = appMenu

        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = editMenu

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = windowMenu

        return main
    }
}
