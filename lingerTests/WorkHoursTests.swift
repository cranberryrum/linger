import Foundation
import Testing
@testable import linger

@Suite struct WorkHoursTests {
    // A fixed zone with DST, so the tests don't depend on the Mac running them.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private let weekdays = WorkHours.standard // Mon–Fri, 9:00–18:00

    // 2026-10-19 is a Monday.
    @Test func workingInsideWeekdayHours() {
        #expect(weekdays.isWorking(at: date(2026, 10, 19, 9), calendar: Self.calendar))
        #expect(weekdays.isWorking(at: date(2026, 10, 19, 17, 59), calendar: Self.calendar))
        #expect(!weekdays.isWorking(at: date(2026, 10, 19, 18), calendar: Self.calendar))
        #expect(!weekdays.isWorking(at: date(2026, 10, 19, 8, 59), calendar: Self.calendar))
    }

    @Test func weekendIsOff() {
        #expect(!weekdays.isWorking(at: date(2026, 10, 24, 12), calendar: Self.calendar)) // Saturday
        #expect(!weekdays.isWorking(at: date(2026, 10, 25, 12), calendar: Self.calendar)) // Sunday
    }

    @Test func nextStartSkipsTheWeekend() {
        let fridayEvening = date(2026, 10, 23, 19)
        #expect(weekdays.nextStart(after: fridayEvening, calendar: Self.calendar) == date(2026, 10, 26, 9))
        #expect(weekdays.nextEnd(after: fridayEvening, calendar: Self.calendar) == date(2026, 10, 26, 18))
    }

    @Test func nextStartLaterTheSameDay() {
        #expect(weekdays.nextStart(after: date(2026, 10, 19, 7), calendar: Self.calendar) == date(2026, 10, 19, 9))
        #expect(weekdays.nextEnd(after: date(2026, 10, 19, 10), calendar: Self.calendar) == date(2026, 10, 19, 18))
    }

    // 22:00–02:00 selected on Friday only: belongs to Friday, runs into Saturday morning.
    @Test func overnightRangeBelongsToTheDayItStarts() {
        let night = WorkHours(days: [6], start: 22 * 60, end: 2 * 60)
        #expect(night.isWorking(at: date(2026, 10, 23, 23), calendar: Self.calendar))
        #expect(night.isWorking(at: date(2026, 10, 24, 1, 30), calendar: Self.calendar))
        #expect(!night.isWorking(at: date(2026, 10, 24, 2), calendar: Self.calendar))
        #expect(!night.isWorking(at: date(2026, 10, 24, 23), calendar: Self.calendar)) // Saturday isn't selected
        #expect(!night.isWorking(at: date(2026, 10, 23, 1), calendar: Self.calendar)) // Thursday's night isn't either
        #expect(night.nextEnd(after: date(2026, 10, 23, 23), calendar: Self.calendar) == date(2026, 10, 24, 2))
    }

    @Test func equalTimesMeanTheWholeDay() {
        let allDay = WorkHours(days: [2], start: 0, end: 0)
        #expect(allDay.isWorking(at: date(2026, 10, 19, 0), calendar: Self.calendar))
        #expect(allDay.isWorking(at: date(2026, 10, 19, 23, 59), calendar: Self.calendar))
        #expect(!allDay.isWorking(at: date(2026, 10, 20, 0), calendar: Self.calendar))
    }

    @Test func noDaysMeansNeverWorkingAndNoNextStart() {
        let none = WorkHours(days: [], start: 9 * 60, end: 18 * 60)
        #expect(!none.isWorking(at: date(2026, 10, 19, 12), calendar: Self.calendar))
        #expect(none.nextStart(after: date(2026, 10, 19, 12), calendar: Self.calendar) == nil)
        #expect(none.nextEnd(after: date(2026, 10, 19, 12), calendar: Self.calendar) == nil)
    }

    // 2026-03-08: clocks jump from 2:00 to 3:00 in New York. A 2:30 start lands just after the gap.
    @Test func springForwardStartInTheGap() {
        let early = WorkHours(days: [1], start: 2 * 60 + 30, end: 10 * 60)
        let start = early.nextStart(after: date(2026, 3, 8, 0), calendar: Self.calendar)!
        let parts = Self.calendar.dateComponents([.hour, .minute], from: start)
        #expect(parts.hour == 3)
        #expect(early.isWorking(at: date(2026, 3, 8, 4), calendar: Self.calendar))
        #expect(!early.isWorking(at: date(2026, 3, 8, 1, 30), calendar: Self.calendar))
    }

    // 2026-11-01: 1:00–2:00 happens twice. An overnight range still ends at the wall-clock time.
    @Test func fallBackOvernightRange() {
        let night = WorkHours(days: [7], start: 22 * 60, end: 6 * 60) // Saturday night
        #expect(night.isWorking(at: date(2026, 11, 1, 1, 30), calendar: Self.calendar))
        #expect(night.nextEnd(after: date(2026, 10, 31, 23), calendar: Self.calendar) == date(2026, 11, 1, 6))
        #expect(!night.isWorking(at: date(2026, 11, 1, 6), calendar: Self.calendar))
    }

    @Test func overrideEndsAtTheNextFourAM() {
        #expect(WorkHours.nextOverrideEnd(after: date(2026, 10, 19, 21), calendar: Self.calendar) == date(2026, 10, 20, 4))
        #expect(WorkHours.nextOverrideEnd(after: date(2026, 10, 20, 1), calendar: Self.calendar) == date(2026, 10, 20, 4))
        #expect(WorkHours.nextOverrideEnd(after: date(2026, 10, 20, 4), calendar: Self.calendar) == date(2026, 10, 21, 4))
    }

    @Test func roundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(WorkHours.standard)
        #expect(try JSONDecoder().decode(WorkHours.self, from: data) == .standard)
    }
}
