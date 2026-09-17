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
    private var settingsWindowController: SettingsWindowController?
    private var onboardingWindowController: OnboardingWindowController?
    private var hotKey: GlobalHotKey?
    private var chime: NSSound?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = makeMainMenu()
        statusItemController = StatusItemController(scheduler: scheduler) { [weak self] in self?.openSettings() }
        overlayController = BreakOverlayController(scheduler: scheduler)
        hotKey = GlobalHotKey(keyCode: kVK_ANSI_L, modifiers: controlKey | optionKey | cmdKey) { [scheduler] in
            scheduler.startBreakNow()
        }
        scheduler.onBreakCompleted = { [weak self] in self?.playChime() }

        if UserDefaults.standard.bool(forKey: DefaultsKey.hasCompletedOnboarding) {
            scheduler.start()
        } else {
            showOnboarding()
        }
    }

    private func showOnboarding() {
        onboardingWindowController = OnboardingWindowController(scheduler: scheduler) { [weak self] in
            self?.onboardingWindowController = nil
            self?.scheduler.start()
        }
        onboardingWindowController?.show()
    }

    @objc private func openSettings() {
        if settingsWindowController == nil {
            settingsWindowController = SettingsWindowController(scheduler: scheduler)
        }
        settingsWindowController?.show()
    }

    private func playChime() {
        guard UserDefaults.standard.bool(forKey: DefaultsKey.soundOn), let sound = NSSound(named: "Glass") else { return }
        sound.volume = 0.25
        chime = sound
        sound.play()
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
