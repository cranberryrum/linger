import AppKit
import Observation
import SwiftUI

final class StatusItemController {
    private let scheduler: BreakScheduler
    private let openSettingsAction: () -> Void
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var hintPopover: NSPopover?
    private let activeIcon = StatusItemController.makeIcon(paused: false)
    private let pausedIcon = StatusItemController.makeIcon(paused: true)

    private let statusLine = NSMenuItem()
    private let takeBreakItem = NSMenuItem(title: "Take a Break Now", action: #selector(takeBreakNow), keyEquivalent: "")
    private let takeLongBreakItem = NSMenuItem(title: "Take a Long Break Now", action: #selector(takeLongBreakNow), keyEquivalent: "")
    private let startBreaksItem = NSMenuItem(title: "Start Breaks Now", action: #selector(startBreaksNow), keyEquivalent: "")
    private let postponeItem = NSMenuItem(title: "Postpone 5 Minutes", action: #selector(postpone), keyEquivalent: "")
    private let pauseHourItem = NSMenuItem(title: "Pause for 1 Hour", action: #selector(pauseForHour), keyEquivalent: "")
    private let pauseTomorrowItem = NSMenuItem(title: "Pause Until Tomorrow", action: #selector(pauseUntilTomorrow), keyEquivalent: "")
    private let resumeItem = NSMenuItem(title: "Resume", action: #selector(resume), keyEquivalent: "")
    private let endMeetingHoldItem = NSMenuItem(title: "Resume Breaks Now", action: #selector(endMeetingHold), keyEquivalent: "")
    private let updateItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")

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
        statusItem.button?.imagePosition = .imageLeading

        // Holding ⌥ swaps in the long-break item. Alternates pair on the same key equivalent, so the
        // ⌃⌥⌘L hint can't be shown here; the hot key still works and Settings › General lists it.
        takeBreakItem.keyEquivalentModifierMask = []
        takeLongBreakItem.keyEquivalentModifierMask = [.option]
        takeLongBreakItem.isAlternate = true

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        let quitItem = NSMenuItem(title: "Quit linger", action: #selector(quit), keyEquivalent: "q")

        let items = [
            statusLine, .separator(),
            takeBreakItem, takeLongBreakItem, postponeItem, .separator(),
            startBreaksItem, pauseHourItem, pauseTomorrowItem, resumeItem, endMeetingHoldItem, .separator(),
            updateItem, settingsItem, quitItem,
        ]
        for item in items {
            item.target = self
            menu.addItem(item)
        }
        statusItem.menu = menu
    }

    private static func makeIcon(paused: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { _ in
            NSImage(named: "LingerMark")?.draw(in: NSRect(x: 1, y: 5, width: 18, height: 8.5))
            if paused {
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 15, y: 1, width: 3, height: 3)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = paused ? "linger, paused" : "linger"
        return image
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

        let title: String
        let status: String
        switch scheduler.state {
        case .working, .waitingForInputPause:
            if let hold = Self.meetingHoldDescription(scheduler) {
                // The countdown is frozen at the heads-up line; a number that doesn't move would mislead.
                title = ""
                status = hold
            } else {
                title = Self.menuBarTitle(scheduler.remaining, mode: countdown)
                status = "\(scheduler.nextBreakIsLong ? "Long break" : "Next break") in \(Self.clock(scheduler.remaining))"
            }
        case .onBreak:
            title = countdown == .off ? "" : Self.clock(scheduler.remaining)
            status = "Break ends in \(Self.clock(scheduler.remaining))"
        case .paused(let until):
            title = ""
            status = BreakScheduler.pauseDescription(until: until)
        case .suspended:
            title = ""
            status = "Paused while the screen is off"
        case .offHours(let until):
            // Resting is the plain mark: eye.slash means the user paused, and this isn't that.
            title = ""
            status = BreakScheduler.restDescription(until: until)
        }

        // This runs every second; in minutes mode the title changes once a minute, and the same
        // string would still make the menu bar re-layout and redraw.
        let image = paused ? pausedIcon : activeIcon
        if button.image !== image {
            button.image = image
            button.setAccessibilityLabel(paused ? "linger, paused" : "linger")
        }
        if button.title != title { button.title = title }
        if statusLine.title != status { statusLine.title = status }

        let resting = scheduler.isOffHours
        takeBreakItem.isHidden = paused
        takeLongBreakItem.isHidden = paused || !scheduler.longBreaksOn
        postponeItem.isHidden = paused || resting
        postponeItem.isEnabled = scheduler.canPostpone
        startBreaksItem.isHidden = !resting
        pauseHourItem.isHidden = paused || resting
        pauseTomorrowItem.isHidden = paused || resting
        resumeItem.isHidden = !paused
        endMeetingHoldItem.isHidden = paused || resting || scheduler.manualMeetingHoldUntil == nil || scheduler.meeting != nil

        let updater = Updater.shared
        let updateTitle = if updater.readyVersion != nil {
            "Install Update and Relaunch"
        } else if let available = updater.availableVersion {
            "Update to \(available)…"
        } else {
            "Check for Updates…"
        }
        if updateItem.title != updateTitle { updateItem.title = updateTitle }
    }

    private static func meetingHoldDescription(_ scheduler: BreakScheduler) -> String? {
        if let meeting = scheduler.meeting { return "Break after \(meeting.title)" }
        return scheduler.manualMeetingHoldUntil == nil ? nil : "Break after your meeting"
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
    @objc private func takeLongBreakNow() { scheduler.startBreakNow(long: true) }
    @objc private func startBreaksNow() { scheduler.startBreaksNow() }
    @objc private func postpone() { scheduler.postpone(by: 5 * 60) }
    @objc private func pauseForHour() { scheduler.pause(for: 3600) }
    @objc private func pauseUntilTomorrow() { scheduler.pauseUntilTomorrow() }
    @objc private func resume() { scheduler.resume() }
    @objc private func endMeetingHold() { scheduler.endMeetingHold() }

    @objc private func checkForUpdates() { Updater.shared.checkForUpdates() }
    @objc private func openSettings() { openSettingsAction() }

    @objc private func quit() { NSApp.terminate(nil) }
}

private struct RunningHintView: View {
    let nextBreak: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image("LingerMark")
                .resizable()
                .scaledToFit()
                .frame(width: 22, height: 18)
                .accessibilityHidden(true)
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
