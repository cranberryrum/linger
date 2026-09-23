import AppKit
import Observation
import os

private let log = Logger(subsystem: "com.adityakolte.linger", category: "scheduler")

@Observable
final class BreakScheduler {
    enum State: Equatable {
        case working
        case waitingForInputPause(since: Date)
        case onBreak(endsAt: Date)
        case paused(until: Date)
        case suspended(remaining: TimeInterval, at: Date)
    }

    static let idleThreshold: TimeInterval = 180
    static let inputPauseThreshold: TimeInterval = 2
    static let inputPauseCap: TimeInterval = 60
    static let maxPostpones = 3
    static let headsUpLead: TimeInterval = 60
    static let finalCountdownLead: TimeInterval = 10

    private(set) var state: State = .working
    private(set) var nextBreakAt = Date()
    private(set) var remaining: TimeInterval = 0
    private(set) var postponeCount = 0
    private(set) var postponedTotal: TimeInterval = 0

    var workInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(workInterval, forKey: DefaultsKey.workIntervalSec)
            recomputeNextBreak()
            // A shorter interval must never blur the screen while the user is still in Settings;
            // an overdue break gets the normal heads-up lead instead.
            if nextBreakAt.timeIntervalSinceNow < Self.headsUpLead {
                cycleStartedAt = Date().addingTimeInterval(Self.headsUpLead - scheduledLength)
                recomputeNextBreak()
            }
        }
    }

    var breakDuration: TimeInterval {
        didSet { UserDefaults.standard.set(breakDuration, forKey: DefaultsKey.breakDurationSec) }
    }

    var canPostpone: Bool {
        switch state {
        case .working, .waitingForInputPause: postponeCount < Self.maxPostpones
        default: false
        }
    }

    var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    var isRunning: Bool { timer != nil }

    @ObservationIgnored var onBreakCompleted: (() -> Void)?
    @ObservationIgnored var onHeadsUp: (() -> Void)?
    @ObservationIgnored var onFinalCountdown: (() -> Void)?

    @ObservationIgnored private var cycleStartedAt = Date()
    @ObservationIgnored private var headsUpFired = false
    @ObservationIgnored private var finalCountdownFired = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init() {
        let defaults = UserDefaults.standard
        workInterval = defaults.double(forKey: DefaultsKey.workIntervalSec)
        breakDuration = defaults.double(forKey: DefaultsKey.breakDurationSec)
    }

    func start() {
        guard timer == nil else { return }
        restartInterval()
        observeSystemEvents()

        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Everything is computed from the clock, not from tick count, so the system may batch this
        // wakeup with others instead of waking the process on an exact 1 s grid.
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Actions

    func startBreakNow() {
        if case .onBreak = state { return }
        beginBreak()
    }

    func postpone(by amount: TimeInterval) {
        guard canPostpone else { return }
        postponeCount += 1
        postponedTotal += amount
        recomputeNextBreak()
        state = .working
        log.debug("Postponed \(Int(amount)) s (\(self.postponeCount)/\(Self.maxPostpones)), next break at \(self.nextBreakAt)")
    }

    func skipBreak() {
        guard case .onBreak = state else { return }
        log.debug("Break skipped")
        restartInterval()
    }

    func pause(for duration: TimeInterval) {
        pause(until: Date().addingTimeInterval(duration))
    }

    func pauseUntilTomorrow() {
        let sixAM = DateComponents(hour: 6, minute: 0)
        guard let until = Calendar.current.nextDate(after: Date(), matching: sixAM, matchingPolicy: .nextTime) else { return }
        pause(until: until)
    }

    func pauseIndefinitely() {
        pause(until: .distantFuture)
    }

    func resume() {
        guard isPaused else { return }
        log.debug("Resumed")
        restartInterval()
    }

    static func pauseDescription(until: Date) -> String {
        if until == .distantFuture { return "Paused" }
        let time = until.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(until) ? "Paused until \(time)" : "Paused until tomorrow, \(time)"
    }

    // MARK: Cycle

    private func pause(until: Date) {
        state = .paused(until: until)
        remaining = 0
        log.debug("Paused until \(until)")
    }

    private func restartInterval() {
        cycleStartedAt = Date()
        postponeCount = 0
        postponedTotal = 0
        recomputeNextBreak()
        state = .working
        log.debug("Interval restarted, next break at \(self.nextBreakAt)")
    }

    private func recomputeNextBreak() {
        nextBreakAt = cycleStartedAt.addingTimeInterval(scheduledLength)
        remaining = max(0, nextBreakAt.timeIntervalSinceNow)
        headsUpFired = false
        finalCountdownFired = false
    }

    private var scheduledLength: TimeInterval {
        workInterval + postponedTotal
    }

    private func beginBreak() {
        let endsAt = Date().addingTimeInterval(breakDuration)
        state = .onBreak(endsAt: endsAt)
        remaining = breakDuration
        log.debug("Break started, ends at \(endsAt)")
    }

    private func endBreak() {
        log.debug("Break ended")
        restartInterval()
        onBreakCompleted?()
    }

    // MARK: Tick

    private func tick() {
        let now = Date()
        switch state {
        case .working:
            if secondsSinceLastInput >= Self.idleThreshold {
                // Being away counts as a break; keep the full interval ahead of the user.
                cycleStartedAt = now
                postponeCount = 0
                postponedTotal = 0
                recomputeNextBreak()
                return
            }
            // A backwards clock jump must never make the wait longer than the interval.
            if nextBreakAt.timeIntervalSince(now) > scheduledLength {
                cycleStartedAt = now
                recomputeNextBreak()
            }
            remaining = max(0, nextBreakAt.timeIntervalSince(now))
            if remaining <= Self.headsUpLead && remaining > 0 && !headsUpFired {
                headsUpFired = true
                onHeadsUp?()
            }
            if remaining <= Self.finalCountdownLead && remaining > 0 && !finalCountdownFired {
                finalCountdownFired = true
                onFinalCountdown?()
            }
            if now >= nextBreakAt {
                if secondsSinceLastInput < Self.inputPauseThreshold {
                    state = .waitingForInputPause(since: now)
                    log.debug("Break due but user is active, waiting for input pause")
                } else {
                    beginBreak()
                }
            }

        case .waitingForInputPause(let since):
            remaining = 0
            if secondsSinceLastInput >= Self.inputPauseThreshold || now.timeIntervalSince(since) >= Self.inputPauseCap {
                beginBreak()
            }

        case .onBreak(let endsAt):
            remaining = max(0, endsAt.timeIntervalSince(now))
            if now >= endsAt { endBreak() }

        case .paused(let until):
            if now >= until { resume() }

        case .suspended:
            break
        }
    }

    var secondsSinceLastInput: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: Debug

    // Moves the current cycle so the next break is `seconds` away, keeping postpones.
    func debugSetRemaining(_ seconds: TimeInterval) {
        switch state {
        case .working, .waitingForInputPause, .paused, .suspended:
            cycleStartedAt = Date().addingTimeInterval(seconds - scheduledLength)
            recomputeNextBreak()
            state = .working
        case .onBreak:
            return
        }
    }

    // Runs the real sleep/wake path as if the Mac had been asleep for `gap` seconds.
    func debugSimulateSleep(gap: TimeInterval) {
        suspend()
        if case .suspended(let remaining, _) = state {
            state = .suspended(remaining: remaining, at: Date().addingTimeInterval(-gap))
        }
        resumeFromSuspension()
    }

    // MARK: Sleep, lock, screensaver

    private func observeSystemEvents() {
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        let suspendNames: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.willSleepNotification),
            (workspace, NSWorkspace.screensDidSleepNotification),
            (distributed, Notification.Name("com.apple.screenIsLocked")),
            (distributed, Notification.Name("com.apple.screensaver.didstart")),
        ]
        let resumeNames: [(NotificationCenter, Notification.Name)] = [
            (workspace, NSWorkspace.didWakeNotification),
            (workspace, NSWorkspace.screensDidWakeNotification),
            (distributed, Notification.Name("com.apple.screenIsUnlocked")),
            (distributed, Notification.Name("com.apple.screensaver.didstop")),
        ]

        for (center, name) in suspendNames {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            })
        }
        for (center, name) in resumeNames {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.resumeFromSuspension() }
            })
        }
    }

    private func suspend() {
        let now = Date()
        switch state {
        case .working:
            state = .suspended(remaining: max(0, nextBreakAt.timeIntervalSince(now)), at: now)
        case .waitingForInputPause:
            state = .suspended(remaining: 0, at: now)
        case .onBreak:
            // The screen is going away anyway; count this break as taken.
            state = .suspended(remaining: workInterval, at: now)
        case .paused, .suspended:
            return
        }
        log.debug("Suspended (sleep/lock)")
    }

    private func resumeFromSuspension() {
        guard case .suspended(let remaining, let at) = state else { return }
        let gap = Date().timeIntervalSince(at)
        if gap >= breakDuration {
            log.debug("Woke after \(Int(gap)) s, counting it as a break")
            restartInterval()
        } else {
            cycleStartedAt = Date().addingTimeInterval(remaining - scheduledLength)
            recomputeNextBreak()
            state = .working
            log.debug("Woke after \(Int(gap)) s, resuming with \(Int(remaining)) s left")
        }
    }
}
