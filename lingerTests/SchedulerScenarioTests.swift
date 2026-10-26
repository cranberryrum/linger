import Foundation
import Testing
@testable import linger

// Drives the real scheduler through the paths the Debug pane and menu use. Settings persist to the
// app's own defaults, so every test restores them afterwards.
@MainActor @Suite(.serialized) struct SchedulerScenarioTests {
    private func withScheduler(freshInstall: Bool = false, _ body: (BreakScheduler) throws -> Void) rethrows {
        let domain = Bundle.main.bundleIdentifier ?? "com.adityakolte.linger"
        let saved = UserDefaults.standard.persistentDomain(forName: domain)
        defer {
            if let saved { UserDefaults.standard.setPersistentDomain(saved, forName: domain) }
            else { UserDefaults.standard.removePersistentDomain(forName: domain) }
        }
        if freshInstall { UserDefaults.standard.removePersistentDomain(forName: domain) }
        DefaultsKey.registerDefaults()
        let scheduler = BreakScheduler()
        scheduler.workInterval = 20 * 60
        scheduler.breakDuration = 20
        scheduler.start()
        try body(scheduler)
    }

    // Every day but today, so "now" is outside work hours whatever the time.
    private var everyDayButToday: WorkHours {
        let today = Calendar.current.component(.weekday, from: Date())
        return WorkHours(days: Set(1...7).subtracting([today]), start: 9 * 60, end: 18 * 60)
    }

    private var allDayEveryDay: WorkHours { WorkHours(days: Set(1...7), start: 0, end: 0) }

    @Test func settingsChangeOutsideHoursRestsQuietly() {
        withScheduler { scheduler in
            scheduler.workHours = everyDayButToday
            scheduler.workHoursOn = true
            #expect(scheduler.state == .offHours(until: everyDayButToday.nextStart(after: Date())))
            #expect(scheduler.remaining == 0)
        }
    }

    @Test func startBreaksNowRunsUntilFourAMWithAFreshInterval() {
        withScheduler { scheduler in
            scheduler.workHours = everyDayButToday
            scheduler.workHoursOn = true
            scheduler.startBreaksNow()
            #expect(scheduler.state == .working)
            #expect(scheduler.scheduleOverride == .init(working: true, until: WorkHours.nextOverrideEnd(after: Date())))
            #expect(abs(scheduler.remaining - 20 * 60) < 2)
        }
    }

    @Test func turningWorkHoursOffWhileRestingStartsAFreshInterval() {
        withScheduler { scheduler in
            scheduler.workHours = everyDayButToday
            scheduler.workHoursOn = true
            scheduler.workHoursOn = false
            #expect(scheduler.state == .working)
            #expect(abs(scheduler.remaining - 20 * 60) < 2)
        }
    }

    @Test func jumpToEndRestsUntilTheNextStartAndEndsAMeetingHold() {
        withScheduler { scheduler in
            scheduler.workHours = allDayEveryDay
            scheduler.workHoursOn = true
            #expect(scheduler.state == .working)
            scheduler.holdUntilMeetingEnds(Date().addingTimeInterval(3600))
            #expect(scheduler.isHoldingForMeeting)
            scheduler.debugJumpToEndOfWorkHours()
            #expect(scheduler.isOffHours)
            #expect(scheduler.manualMeetingHoldUntil == nil)
        }
    }

    @Test func jumpToStartIsANewDay() {
        withScheduler { scheduler in
            scheduler.longBreaksOn = true
            scheduler.debugForceNextLong()
            scheduler.workHours = everyDayButToday
            scheduler.workHoursOn = true
            scheduler.debugJumpToStartOfWorkHours()
            #expect(scheduler.state == .working)
            #expect(!scheduler.longBreaks.forceNextLong)
            #expect(abs(scheduler.remaining - 20 * 60) < 2)
        }
    }

    @Test func pauseUntilTomorrowResumesAtTheNextWorkHoursStart() {
        withScheduler { scheduler in
            scheduler.workHours = allDayEveryDay
            scheduler.workHoursOn = true
            scheduler.pauseUntilTomorrow()
            #expect(scheduler.state == .paused(until: allDayEveryDay.nextStart(after: Date())!))
        }
    }

    @Test func longBreakRunsTheLongDurationAndASkipKeepsItOwed() {
        withScheduler { scheduler in
            scheduler.longBreaksOn = true
            scheduler.longBreakDuration = 180
            scheduler.debugForceNextLong()
            #expect(scheduler.nextBreakIsLong)
            scheduler.startBreakNow()
            #expect(scheduler.currentBreakIsLong)
            #expect(scheduler.currentBreakDuration == 180)
            scheduler.skipBreak()
            #expect(scheduler.nextBreakIsLong)
        }
    }

    @Test func takeALongBreakNowIsLongEvenWhenNotDue() {
        withScheduler { scheduler in
            scheduler.longBreaksOn = true
            #expect(!scheduler.nextBreakIsLong)
            scheduler.startBreakNow(long: true)
            #expect(scheduler.currentBreakIsLong)
        }
    }

    @Test func sleepLongerThanALongBreakCountsAsOne() {
        withScheduler { scheduler in
            scheduler.longBreaksOn = true
            scheduler.longBreakDuration = 120
            scheduler.debugForceNextLong()
            scheduler.debugSimulateSleep(gap: 60)
            #expect(scheduler.nextBreakIsLong)
            scheduler.debugSimulateSleep(gap: 5 * 60)
            #expect(!scheduler.nextBreakIsLong)
        }
    }

    @Test func featuresOffByDefault() {
        withScheduler(freshInstall: true) { scheduler in
            #expect(!scheduler.workHoursOn)
            #expect(!scheduler.longBreaksOn)
            #expect(!scheduler.nextBreakIsLong)
            #expect(scheduler.state == .working)
        }
    }

    @Test func timerMatchesTheSliderAfterAChange() {
        withScheduler { scheduler in
            scheduler.debugSetRemaining(7 * 60)
            scheduler.workInterval = 30 * 60
            #expect(Int(scheduler.remaining.rounded(.up)) == 30 * 60)
            scheduler.workInterval = 5 * 60
            #expect(Int(scheduler.remaining.rounded(.up)) == 5 * 60)
        }
    }
}
