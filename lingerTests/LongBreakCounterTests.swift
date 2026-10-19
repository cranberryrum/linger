import Testing
@testable import linger

@Suite struct LongBreakCounterTests {
    @Test func everyThirdBreakIsLong() {
        var counter = LongBreakCounter()
        #expect(!counter.nextIsLong(every: 3))
        counter.breakCompleted(long: false)
        #expect(!counter.nextIsLong(every: 3))
        counter.breakCompleted(long: false)
        #expect(counter.nextIsLong(every: 3))
        counter.breakCompleted(long: true)
        #expect(!counter.nextIsLong(every: 3))
        #expect(counter.completedShort == 0)
    }

    @Test func everySecondBreakIsLong() {
        var counter = LongBreakCounter()
        counter.breakCompleted(long: false)
        #expect(counter.nextIsLong(every: 2))
    }

    // Skips never reach the counter, so a skipped long break is still owed.
    @Test func skippedLongBreakStaysDue() {
        var counter = LongBreakCounter()
        counter.breakCompleted(long: false)
        counter.breakCompleted(long: false)
        #expect(counter.nextIsLong(every: 3))
        // (skip: no call)
        #expect(counter.nextIsLong(every: 3))
    }

    @Test func timeAwayCountsOnlyWhenLongEnough() {
        var counter = LongBreakCounter()
        counter.breakCompleted(long: false)
        counter.breakCompleted(long: false)
        counter.creditAway(179, longDuration: 180)
        #expect(counter.nextIsLong(every: 3))
        counter.creditAway(180, longDuration: 180)
        #expect(!counter.nextIsLong(every: 3))
        #expect(counter.completedShort == 0)
    }

    @Test func forcedLongBreakClearsOnceTaken() {
        var counter = LongBreakCounter()
        counter.forceNextLong = true
        #expect(counter.nextIsLong(every: 6))
        counter.breakCompleted(long: true)
        #expect(!counter.forceNextLong)
        #expect(!counter.nextIsLong(every: 6))
    }
}
