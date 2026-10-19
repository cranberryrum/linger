import Foundation

// The hours breaks run. A pure schedule: it answers questions about dates and nothing else.
nonisolated struct WorkHours: Equatable, Codable {
    // Calendar weekdays, 1 = Sunday … 7 = Saturday. A range belongs to the day it starts.
    var days: Set<Int>
    // Minutes from midnight. `end <= start` means the range runs past midnight into the next day;
    // equal times mean the whole 24 hours.
    var start: Int
    var end: Int

    static let standard = WorkHours(days: [2, 3, 4, 5, 6], start: 9 * 60, end: 18 * 60)

    func isWorking(at date: Date, calendar: Calendar = .current) -> Bool {
        ranges(around: date, dayOffsets: -1...0, calendar: calendar).contains { $0.start <= date && date < $0.end }
    }

    func nextStart(after date: Date, calendar: Calendar = .current) -> Date? {
        ranges(around: date, dayOffsets: -1...8, calendar: calendar).map(\.start).filter { $0 > date }.min()
    }

    func nextEnd(after date: Date, calendar: Calendar = .current) -> Date? {
        ranges(around: date, dayOffsets: -1...8, calendar: calendar).map(\.end).filter { $0 > date }.min()
    }

    // "Start Breaks Now" outside work hours lasts until the small hours, then the schedule takes over.
    static func nextOverrideEnd(after date: Date, calendar: Calendar = .current) -> Date {
        let today = calendar.startOfDay(for: date)
        for offset in 0...1 {
            if let day = calendar.date(byAdding: .day, value: offset, to: today),
               let fourAM = time(4 * 60, on: day, calendar: calendar), fourAM > date {
                return fourAM
            }
        }
        return date.addingTimeInterval(24 * 60 * 60)
    }

    private func ranges(around date: Date, dayOffsets: ClosedRange<Int>, calendar: Calendar) -> [(start: Date, end: Date)] {
        let today = calendar.startOfDay(for: date)
        return dayOffsets.compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: today).flatMap { range(startingOn: $0, calendar: calendar) }
        }
    }

    private func range(startingOn day: Date, calendar: Calendar) -> (start: Date, end: Date)? {
        guard days.contains(calendar.component(.weekday, from: day)),
              let endDay = end > start ? day : calendar.date(byAdding: .day, value: 1, to: day),
              let startDate = Self.time(start, on: day, calendar: calendar),
              let endDate = Self.time(end, on: endDay, calendar: calendar)
        else { return nil }
        return (startDate, endDate)
    }

    // Built from components so a time skipped by a DST change lands just after the gap, and a
    // repeated hour resolves to its first occurrence.
    private static func time(_ minutes: Int, on day: Date, calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = minutes / 60
        components.minute = minutes % 60
        return calendar.date(from: components)
    }
}
