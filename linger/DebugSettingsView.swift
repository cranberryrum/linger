import SwiftUI

struct DebugActions {
    var showHeadsUp: () -> Void
    var showRunningHint: () -> Void
    var showOnboarding: () -> Void
}

struct DebugSettingsView: View {
    let scheduler: BreakScheduler
    let actions: DebugActions
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section("Live state") {
                LabeledContent("State", value: stateDescription)
                LabeledContent("Next break", value: scheduler.nextBreakAt.formatted(date: .omitted, time: .standard))
                LabeledContent("Remaining", value: "\(Int(scheduler.remaining.rounded(.up))) s")
                LabeledContent("Postpones", value: "\(scheduler.postponeCount)/\(BreakScheduler.maxPostpones) · +\(Int(scheduler.postponedTotal / 60)) min")
                LabeledContent("Last input", value: "\(Int(scheduler.secondsSinceLastInput)) s ago")
                LabeledContent("Meeting", value: meetingDescription)
                LabeledContent("Work hours", value: workHoursDescription)
                LabeledContent("Long breaks", value: longBreaksDescription)
                LabeledContent("Skip mode", value: SkipDifficulty.current.rawValue)
            }
            .monospacedDigit()

            Section("Jump to") {
                Button("Heads-up panel (break in 70 s)") { scheduler.debugSetRemaining(70) }
                Button("Cursor countdown (break in 12 s)") { scheduler.debugSetRemaining(12) }
                Button("Break due now (typing defers it)") { scheduler.debugSetRemaining(1) }
                Button("Break now") { scheduler.startBreakNow() }
                Button("Next break is long") { scheduler.debugForceNextLong() }
                    .disabled(!scheduler.longBreaksOn)
                Button("End of work hours (rest until the next start)") { scheduler.debugJumpToEndOfWorkHours() }
                    .disabled(!scheduler.workHoursOn)
                Button("Start of work hours (fresh interval)") { scheduler.debugJumpToStartOfWorkHours() }
                    .disabled(!scheduler.workHoursOn)
            }

            Section("Simulate") {
                Button("Sleep 5 s, wake (resumes where it left off)") { scheduler.debugSimulateSleep(gap: 5) }
                Button("Sleep 60 s, wake (counts as a break taken)") { scheduler.debugSimulateSleep(gap: 60) }
                Button("Sleep 5 min, wake (counts as a long break too)") { scheduler.debugSimulateSleep(gap: 5 * 60) }
                Button("Meeting for 45 s (break waits, heads-up follows)") { scheduler.debugSimulateMeeting(for: 45) }
                Button("Postpone 5 min") { scheduler.postpone(by: 5 * 60) }
                    .disabled(!scheduler.canPostpone)
                if scheduler.isPaused {
                    Button("Resume") { scheduler.resume() }
                } else {
                    Button("Pause for 1 hour") { scheduler.pause(for: 3600) }
                }
            }

            Section("Surfaces") {
                Button("Show heads-up panel") { actions.showHeadsUp() }
                Button("Show menu bar hint") { actions.showRunningHint() }
            }

            Section("Sounds") {
                Button("Tik tik (10 s before a break)") { Sounds.play(.finalCountdown, ignoringPreference: true) }
                Button("Break start") { Sounds.play(.breakStart, ignoringPreference: true) }
                Button("Skip") { Sounds.play(.skip, ignoringPreference: true) }
                Button("Break end") { Sounds.play(.breakEnd, ignoringPreference: true) }
                Button("Whole sequence") { playSequence() }
            }

            Section {
                Button("Run onboarding again") { actions.showOnboarding() }
                Button("Reset all settings…", role: .destructive) { confirmReset = true }
            } footer: {
                Text("Reset clears every preference and quits linger. Relaunch to start as a fresh install.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset all settings and quit?", isPresented: $confirmReset) {
            Button("Reset and Quit", role: .destructive) { resetAndQuit() }
        }
    }

    private var stateDescription: String {
        switch scheduler.state {
        case .working: "working"
        case .waitingForInputPause(let since): "waiting for input pause (\(Int(Date().timeIntervalSince(since))) s)"
        case .onBreak(let endsAt): "on break, ends \(endsAt.formatted(date: .omitted, time: .standard))"
        case .paused(let until): BreakScheduler.pauseDescription(until: until).lowercased()
        case .suspended(let remaining, _): "suspended, \(Int(remaining)) s left"
        case .offHours(let until): "off hours, " + (until.map { "until \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "no days selected")
        }
    }

    private var workHoursDescription: String {
        guard scheduler.workHoursOn else { return "off" }
        guard let override = scheduler.scheduleOverride else { return "on, following the schedule" }
        return "overridden (\(override.working ? "working" : "resting")) until \(override.until.formatted(date: .abbreviated, time: .shortened))"
    }

    // The only place the counter is ever visible.
    private var longBreaksDescription: String {
        guard scheduler.longBreaksOn else { return "off" }
        let counter = scheduler.longBreaks
        if counter.forceNextLong { return "next forced long" }
        let left = max(0, scheduler.longBreakEvery - 1 - counter.completedShort)
        return "\(counter.completedShort) short done · " + (left == 0 ? "next is long" : "long after \(left) more")
    }

    private var meetingDescription: String {
        if let meeting = scheduler.meeting {
            return "\(meeting.title), until \(meeting.end.formatted(date: .omitted, time: .shortened))"
        }
        return scheduler.manualMeetingHoldUntil.map { "held until \($0.formatted(date: .omitted, time: .shortened))" } ?? "none"
    }

    // Tik tik → start → end, with the real gaps compressed, to judge the palette as a whole.
    private func playSequence() {
        Task {
            Sounds.play(.finalCountdown, ignoringPreference: true)
            try? await Task.sleep(for: .seconds(1.5))
            Sounds.play(.breakStart, ignoringPreference: true)
            try? await Task.sleep(for: .seconds(4))
            Sounds.play(.breakEnd, ignoringPreference: true)
        }
    }

    private func resetAndQuit() {
        UserDefaults.standard.removePersistentDomain(forName: Bundle.main.bundleIdentifier ?? "com.adityakolte.linger")
        NSApp.terminate(nil)
    }
}
