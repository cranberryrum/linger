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
        // Outside work hours. Not a pause: nobody asked for it, and it ends on its own. Nil when no
        // day is selected, so there is no next start.
        case offHours(until: Date?)
    }

    // "Start Breaks Now" off hours (working) or a Debug jump (either way), until a moment.
    struct ScheduleOverride: Equatable {
        let working: Bool
        let until: Date
    }

    static let idleThreshold: TimeInterval = 180
    static let inputPauseThreshold: TimeInterval = 2
    static let inputPauseCap: TimeInterval = 60
    static let maxPostpones = 3
    static let headsUpLead: TimeInterval = 60
    static let finalCountdownLead: TimeInterval = 10
    // What one heads-up card may add in total, however many pills are clicked.
    static let maxPostponePerHeadsUp: TimeInterval = 15 * 60
    // A calendar event that runs all afternoon still doesn't switch breaks off for longer than this.
    static let manualMeetingHoldCap: TimeInterval = 3 * 60 * 60

    private(set) var state: State = .working
    private(set) var nextBreakAt = Date()
    private(set) var remaining: TimeInterval = 0
    private(set) var postponeCount = 0
    private(set) var postponedTotal: TimeInterval = 0
    // A call or presentation linger has detected; while set, the break waits at the heads-up line.
    private(set) var meeting: CalendarMeeting?
    // The user said "after meeting" on the heads-up.
    private(set) var manualMeetingHoldUntil: Date?
    private(set) var scheduleOverride: ScheduleOverride?
    private(set) var longBreaks = LongBreakCounter()
    // The break on screen now; long breaks run longer than `breakDuration`.
    private(set) var currentBreakIsLong = false
    private(set) var currentBreakDuration: TimeInterval = 0

    var workInterval: TimeInterval {
        didSet {
            UserDefaults.standard.set(workInterval, forKey: DefaultsKey.workIntervalSec)
            // The countdown always reads what the slider says: a new interval starts from now, so the
            // timer shows the full value instead of what's left after the time already worked.
            guard workInterval != oldValue else { return }
            switch state {
            case .working, .waitingForInputPause: restartInterval()
            case .onBreak, .paused, .suspended, .offHours: break
            }
        }
    }

    var breakDuration: TimeInterval {
        didSet { UserDefaults.standard.set(breakDuration, forKey: DefaultsKey.breakDurationSec) }
    }

    var workHoursOn: Bool {
        didSet {
            UserDefaults.standard.set(workHoursOn, forKey: DefaultsKey.workHoursOn)
            scheduleChanged()
        }
    }

    var workHours: WorkHours {
        didSet {
            workHours.store()
            scheduleChanged()
        }
    }

    var longBreaksOn: Bool {
        didSet {
            UserDefaults.standard.set(longBreaksOn, forKey: DefaultsKey.longBreaksOn)
            // Counting starts when the feature does, not from breaks taken while it was off.
            longBreaks.reset()
        }
    }

    var longBreakEvery: Int {
        didSet { UserDefaults.standard.set(longBreakEvery, forKey: DefaultsKey.longBreakEvery) }
    }

    var longBreakDuration: TimeInterval {
        didSet { UserDefaults.standard.set(longBreakDuration, forKey: DefaultsKey.longBreakDurationSec) }
    }

    var nextBreakIsLong: Bool { longBreaksOn && longBreaks.nextIsLong(every: longBreakEvery) }

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

    var isOffHours: Bool {
        if case .offHours = state { return true }
        return false
    }

    var isHoldingForMeeting: Bool { meeting != nil || manualMeetingHoldUntil != nil }

    @ObservationIgnored var onBreakCompleted: (() -> Void)?
    @ObservationIgnored var onHeadsUp: (() -> Void)?
    @ObservationIgnored var onFinalCountdown: (() -> Void)?

    @ObservationIgnored private var cycleStartedAt = Date()
    @ObservationIgnored private var headsUpFired = false
    @ObservationIgnored private var finalCountdownFired = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var lastMeetingCheck: Date = .distantPast
    @ObservationIgnored private var debugMeetingUntil: Date?
    @ObservationIgnored private var pausedAt: Date?
    // Whether breaks should run, and until when that answer holds; nil means "until something changes".
    @ObservationIgnored private var workingCache: (working: Bool, until: Date?)?

    init() {
        let defaults = UserDefaults.standard
        workInterval = defaults.double(forKey: DefaultsKey.workIntervalSec)
        breakDuration = defaults.double(forKey: DefaultsKey.breakDurationSec)
        workHoursOn = defaults.bool(forKey: DefaultsKey.workHoursOn)
        workHours = .stored
        longBreaksOn = defaults.bool(forKey: DefaultsKey.longBreaksOn)
        longBreakEvery = defaults.integer(forKey: DefaultsKey.longBreakEvery)
        longBreakDuration = defaults.double(forKey: DefaultsKey.longBreakDurationSec)
    }

    func start() {
        guard timer == nil else { return }
        restartInterval()
        applyWorkHours(now: Date())
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

    // Nil takes the next break as scheduled, long if one is due.
    func startBreakNow(long: Bool? = nil) {
        if case .onBreak = state { return }
        beginBreak(long: long)
    }

    // Off hours, breaks run until the small hours; then the schedule takes back over.
    func startBreaksNow() {
        let now = Date()
        setOverride(ScheduleOverride(working: true, until: WorkHours.nextOverrideEnd(after: now)), now: now)
    }

    func postpone(by amount: TimeInterval) {
        guard canPostpone else { return }
        postponeCount += 1
        postponedTotal += amount
        recomputeNextBreak()
        state = .working
        log.debug("Postponed \(Int(amount)) s (\(self.postponeCount)/\(Self.maxPostpones)), next break at \(self.nextBreakAt)")
    }

    // Further clicks on the same heads-up stretch the postpone already counted instead of using up another.
    func extendPostpone(by amount: TimeInterval) {
        guard postponeCount > 0 else { return }
        switch state {
        case .working, .waitingForInputPause: break
        default: return
        }
        postponedTotal += amount
        recomputeNextBreak()
        state = .working
        log.debug("Extended postpone by \(Int(amount)) s, next break at \(self.nextBreakAt)")
    }

    // Holds the break until the calendar meeting ends.
    func holdUntilMeetingEnds(_ end: Date) {
        switch state {
        case .working, .waitingForInputPause: break
        default: return
        }
        manualMeetingHoldUntil = min(end, Date().addingTimeInterval(Self.manualMeetingHoldCap))
        state = .working
        holdAtHeadsUpLine(now: Date())
        log.debug("Holding breaks until the meeting ends")
    }

    func endMeetingHold() {
        guard manualMeetingHoldUntil != nil else { return }
        manualMeetingHoldUntil = nil
        log.debug("Meeting hold ended by the user")
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
        let now = Date()
        if workHoursOn, let start = workHours.nextStart(after: now) {
            pause(until: start)
            return
        }
        let sixAM = DateComponents(hour: 6, minute: 0)
        guard let until = Calendar.current.nextDate(after: now, matching: sixAM, matchingPolicy: .nextTime) else { return }
        pause(until: until)
    }

    func pauseIndefinitely() {
        pause(until: .distantFuture)
    }

    func resume() {
        guard isPaused else { return }
        log.debug("Resumed")
        if let pausedAt { creditAway(Date().timeIntervalSince(pausedAt)) }
        pausedAt = nil
        restartInterval()
        applyWorkHours(now: Date())
    }

    static func pauseDescription(until: Date) -> String {
        if until == .distantFuture { return "Paused" }
        let time = until.formatted(date: .omitted, time: .shortened)
        return Calendar.current.isDateInToday(until) ? "Paused until \(time)" : "Paused until tomorrow, \(time)"
    }

    // "9:00" when the next start is today or tomorrow, "Mon 9:00" when it's further off.
    static func restTime(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) || calendar.isDateInTomorrow(date) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    static func restDescription(until: Date?) -> String {
        until.map { "Resting until \(restTime($0))" } ?? "Resting"
    }

    // MARK: Cycle

    private func pause(until: Date) {
        if pausedAt == nil { pausedAt = Date() }
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

    private func beginBreak(long: Bool? = nil) {
        // Taking a break, by choice or on schedule, settles any "after meeting" promise.
        manualMeetingHoldUntil = nil
        currentBreakIsLong = long ?? nextBreakIsLong
        currentBreakDuration = currentBreakIsLong ? longBreakDuration : breakDuration
        let endsAt = Date().addingTimeInterval(currentBreakDuration)
        state = .onBreak(endsAt: endsAt)
        remaining = currentBreakDuration
        log.debug("\(self.currentBreakIsLong ? "Long break" : "Break") started, ends at \(endsAt)")
    }

    private func endBreak() {
        log.debug("Break ended")
        breakTaken()
        restartInterval()
        onBreakCompleted?()
        applyWorkHours(now: Date())
    }

    // MARK: Long breaks

    private func breakTaken() {
        guard longBreaksOn else { return }
        longBreaks.breakCompleted(long: currentBreakIsLong)
    }

    private func creditAway(_ seconds: TimeInterval) {
        guard longBreaksOn else { return }
        longBreaks.creditAway(seconds, longDuration: longBreakDuration)
    }

    // MARK: Work hours

    private func scheduleChanged() {
        workingCache = nil
        // Not before start(): the first evaluation happens there.
        guard timer != nil else { return }
        applyWorkHours(now: Date())
    }

    private func setOverride(_ override: ScheduleOverride?, now: Date) {
        scheduleOverride = override
        workingCache = nil
        applyWorkHours(now: now)
    }

    private func shouldRunBreaks(at now: Date) -> (working: Bool, until: Date?) {
        if let cache = workingCache, cache.until.map({ now < $0 }) ?? true { return cache }
        if let override = scheduleOverride, now >= override.until { scheduleOverride = nil }

        let answer: (working: Bool, until: Date?)
        if let override = scheduleOverride {
            answer = (override.working, override.until)
        } else if !workHoursOn {
            answer = (true, nil)
        } else if workHours.isWorking(at: now) {
            answer = (true, workHours.nextEnd(after: now))
        } else {
            answer = (false, workHours.nextStart(after: now))
        }
        workingCache = answer
        return answer
    }

    // Every work-hours boundary rule lives here. Runs each tick (cheaply, from the cache) and
    // whenever something that could move the boundary changes.
    private func applyWorkHours(now: Date) {
        let schedule = shouldRunBreaks(at: now)
        switch state {
        case .working, .waitingForInputPause:
            guard !schedule.working else { return }
            // A meeting hold that crosses the end of the day just ends; nothing waits for morning.
            manualMeetingHoldUntil = nil
            state = .offHours(until: schedule.until)
            remaining = 0
            log.debug("Off hours until \(String(describing: schedule.until))")
        case .offHours(let until):
            if schedule.working {
                // A new working day starts fresh: a full interval, and long-break counting from zero.
                longBreaks.reset()
                restartInterval()
            } else if until != schedule.until {
                state = .offHours(until: schedule.until)
            }
        case .onBreak, .paused, .suspended:
            // A break finishes, a pause wins while it lasts, sleep is handled on wake.
            break
        }
    }


    // MARK: Tick

    private func tick() {
        let now = Date()
        applyWorkHours(now: now)
        updateMeeting(now: now)
        switch state {
        case .working:
            // In a meeting nobody touches the keyboard, but the eyes are usually still on the screen.
            let idle = secondsSinceLastInput
            if meeting == nil, idle >= Self.idleThreshold {
                // Being away counts as a break; keep the full interval ahead of the user. Long
                // enough away, it counts as a long one too.
                creditAway(idle)
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
            if isHoldingForMeeting { holdAtHeadsUpLine(now: now) }
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
            if isHoldingForMeeting {
                state = .working
                holdAtHeadsUpLine(now: now)
                return
            }
            remaining = 0
            if secondsSinceLastInput >= Self.inputPauseThreshold || now.timeIntervalSince(since) >= Self.inputPauseCap {
                beginBreak()
            }

        case .onBreak(let endsAt):
            remaining = max(0, endsAt.timeIntervalSince(now))
            if now >= endsAt { endBreak() }

        case .paused(let until):
            if now >= until { resume() }

        case .suspended, .offHours:
            break
        }
    }

    // MARK: Meetings

    // The calendar is the only source: a meeting from the chosen calendar that's on right now.
    private static let meetingCheckInterval: TimeInterval = 15

    private func updateMeeting(now: Date) {
        switch state {
        case .working, .waitingForInputPause:
            break
        default:
            // Paused, asleep, resting or on a break: nothing to hold, and no reason to read the calendar.
            if meeting != nil { meeting = nil }
            return
        }

        if let until = manualMeetingHoldUntil, now >= until {
            log.debug("Meeting hold over")
            manualMeetingHoldUntil = nil
        }

        if let until = debugMeetingUntil {
            if now < until {
                if meeting == nil { meeting = CalendarMeeting(title: "Simulated meeting", start: now, end: until) }
                return
            }
            debugMeetingUntil = nil
            lastMeetingCheck = .distantPast
        }

        // A meeting's end is known, so it ends exactly on time between calendar reads.
        if let current = meeting, now >= current.end { meeting = nil }
        guard now.timeIntervalSince(lastMeetingCheck) >= Self.meetingCheckInterval else { return }
        lastMeetingCheck = now
        let found = MeetingCalendar.shared.meetingInProgress(now: now)
        if found != meeting {
            log.debug("Meeting: \(found?.title ?? "none")")
            meeting = found
        }
    }

    // The break never gets closer than the heads-up line while a meeting is on; once it ends,
    // the heads-up arrives and the break follows a minute later, never as an instant blur.
    private func holdAtHeadsUpLine(now: Date) {
        let floor = Self.headsUpLead + 1
        guard nextBreakAt.timeIntervalSince(now) < floor else { return }
        cycleStartedAt = now.addingTimeInterval(floor - scheduledLength)
        recomputeNextBreak()
    }

    var secondsSinceLastInput: TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    // MARK: Debug

    // Moves the current cycle so the next break is `seconds` away, keeping postpones.
    func debugSetRemaining(_ seconds: TimeInterval) {
        switch state {
        case .working, .waitingForInputPause, .paused, .suspended, .offHours:
            cycleStartedAt = Date().addingTimeInterval(seconds - scheduledLength)
            recomputeNextBreak()
            state = .working
        case .onBreak:
            return
        }
    }

    func debugForceNextLong() {
        longBreaks.forceNextLong = true
    }

    // Both jumps act as if the boundary had just been crossed, and last until the next real one.
    func debugJumpToEndOfWorkHours() {
        let now = Date()
        let until = workHours.nextStart(after: now) ?? now.addingTimeInterval(8 * 60 * 60)
        setOverride(ScheduleOverride(working: false, until: until), now: now)
    }

    func debugJumpToStartOfWorkHours() {
        let now = Date()
        let until = workHours.nextEnd(after: now) ?? now.addingTimeInterval(8 * 60 * 60)
        let wasOffHours = isOffHours
        setOverride(ScheduleOverride(working: true, until: until), now: now)
        guard !wasOffHours, state == .working || isWaitingForInputPause else { return }
        longBreaks.reset()
        restartInterval()
    }

    private var isWaitingForInputPause: Bool {
        if case .waitingForInputPause = state { return true }
        return false
    }

    func debugSimulateMeeting(for seconds: TimeInterval) {
        debugMeetingUntil = Date().addingTimeInterval(seconds)
        updateMeeting(now: Date())
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
            breakTaken()
            state = .suspended(remaining: workInterval, at: now)
        case .paused, .suspended, .offHours:
            return
        }
        log.debug("Suspended (sleep/lock)")
    }

    private func resumeFromSuspension() {
        guard case .suspended(let remaining, let at) = state else { return }
        let gap = Date().timeIntervalSince(at)
        creditAway(gap)
        defer { applyWorkHours(now: Date()) }
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
