import AppKit
import Observation
import SwiftUI

final class StatusItemController {
    private let scheduler: BreakScheduler
    private let openSettingsAction: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hintPopover: NSPopover?

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
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)

        // Display only: the Carbon hot key does the real work, and startBreakNow is idempotent.
        takeBreakItem.keyEquivalent = "l"
        takeBreakItem.keyEquivalentModifierMask = [.control, .option, .command]

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
        let countdown = MenuBarCountdown.current
        let paused = scheduler.isPaused

        button.image = NSImage(systemSymbolName: paused ? "eye.slash" : "eye", accessibilityDescription: "linger")
        button.imagePosition = .imageLeading

        switch scheduler.state {
        case .working, .waitingForInputPause:
            button.title = Self.menuBarTitle(scheduler.remaining, mode: countdown)
            statusLine.title = "Next break in \(Self.clock(scheduler.remaining))"
        case .onBreak:
            button.title = countdown == .off ? "" : Self.clock(scheduler.remaining)
            statusLine.title = "Break ends in \(Self.clock(scheduler.remaining))"
        case .paused(let until):
            button.title = ""
            statusLine.title = BreakScheduler.pauseDescription(until: until)
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

    // Shown once after onboarding so the user knows where the app went.
    func showRunningHint() {
        guard let button = statusItem.button else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: RunningHintView(nextBreak: Self.clock(scheduler.remaining))
        )
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        hintPopover = popover

        Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            self?.hintPopover?.performClose(nil)
            self?.hintPopover = nil
        }
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    // Minutes read as "about"; seconds only appear inside the heads-up window, where they mean something.
    private static func menuBarTitle(_ seconds: TimeInterval, mode: MenuBarCountdown) -> String {
        switch mode {
        case .off: ""
        case .precise: clock(seconds)
        case .minutes: seconds < BreakScheduler.headsUpLead ? clock(seconds) : "\(Int((seconds / 60).rounded(.up)))m"
        }
    }

    // MARK: Menu actions

    @objc private func takeBreakNow() { scheduler.startBreakNow() }
    @objc private func postpone() { scheduler.postpone(by: 5 * 60) }
    @objc private func pauseForHour() { scheduler.pause(for: 3600) }
    @objc private func pauseUntilTomorrow() { scheduler.pauseUntilTomorrow() }
    @objc private func resume() { scheduler.resume() }

    @objc private func openSettings() { openSettingsAction() }

    @objc private func quit() { NSApp.terminate(nil) }
}

private struct RunningHintView: View {
    let nextBreak: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "eye")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text("linger is running here")
                    .fontWeight(.semibold)
                Text("Next break in \(nextBreak). Click the eye to pause, take a break now, or open Settings.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
