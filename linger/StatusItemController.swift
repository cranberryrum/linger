import AppKit
import Observation

final class StatusItemController {
    private let scheduler: BreakScheduler
    private let openSettingsAction: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

    private let statusLine = NSMenuItem()
    private let takeBreakItem = NSMenuItem(title: "Take a Break Now", action: #selector(takeBreakNow), keyEquivalent: "")
    private let postponeItem = NSMenuItem(title: "Postpone 5 Minutes", action: #selector(postpone), keyEquivalent: "")
    private let pauseHourItem = NSMenuItem(title: "Pause for 1 Hour", action: #selector(pauseForHour), keyEquivalent: "")
    private let pauseTomorrowItem = NSMenuItem(title: "Pause Until Tomorrow", action: #selector(pauseUntilTomorrow), keyEquivalent: "")
    private let resumeItem = NSMenuItem(title: "Resume", action: #selector(resume), keyEquivalent: "")

    init(scheduler: BreakScheduler, openSettings: @escaping () -> Void) {
        self.scheduler = scheduler
        self.openSettingsAction = openSettings
        buildMenu()
        observe()
    }

    private func buildMenu() {
        let menu = NSMenu()
        statusLine.isEnabled = false

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        let quitItem = NSMenuItem(title: "Quit linger", action: #selector(quit), keyEquivalent: "q")

        let items = [
            statusLine, .separator(),
            takeBreakItem, postponeItem, .separator(),
            pauseHourItem, pauseTomorrowItem, resumeItem, .separator(),
            settingsItem, quitItem,
        ]
        for item in items {
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
    }

    private func observe() {
        withObservationTracking {
            render()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func render() {
        guard let button = statusItem.button else { return }
        let showCountdown = UserDefaults.standard.bool(forKey: DefaultsKey.showCountdownInMenuBar)
        let paused = scheduler.isPaused

        button.image = NSImage(systemSymbolName: paused ? "eye.slash" : "eye", accessibilityDescription: "linger")
        button.imagePosition = .imageLeading

        switch scheduler.state {
        case .working, .waitingForInputPause:
            button.title = showCountdown ? Self.clock(scheduler.remaining) : ""
            statusLine.title = "Next break in \(Self.clock(scheduler.remaining))"
        case .onBreak:
            button.title = showCountdown ? Self.clock(scheduler.remaining) : ""
            statusLine.title = "Break ends in \(Self.clock(scheduler.remaining))"
        case .paused(let until):
            button.title = ""
            let time = until.formatted(date: .omitted, time: .shortened)
            statusLine.title = Calendar.current.isDateInToday(until) ? "Paused until \(time)" : "Paused until tomorrow, \(time)"
        case .suspended:
            button.title = ""
            statusLine.title = "Paused while the screen is off"
        }

        takeBreakItem.isHidden = paused
        postponeItem.isHidden = paused
        postponeItem.isEnabled = scheduler.canPostpone
        pauseHourItem.isHidden = paused
        pauseTomorrowItem.isHidden = paused
        resumeItem.isHidden = !paused
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: Menu actions

    @objc private func takeBreakNow() { scheduler.startBreakNow() }
    @objc private func postpone() { scheduler.postpone() }
    @objc private func pauseForHour() { scheduler.pause(for: 3600) }
    @objc private func pauseUntilTomorrow() { scheduler.pauseUntilTomorrow() }
    @objc private func resume() { scheduler.resume() }

    @objc private func openSettings() { openSettingsAction() }

    @objc private func quit() { NSApp.terminate(nil) }
}
