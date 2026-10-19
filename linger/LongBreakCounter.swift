import Foundation

// Decides when a break should be a long one. Internal only: it is never shown outside Debug.
nonisolated struct LongBreakCounter: Equatable {
    // Short breaks completed since the last long break (or time away that counted as one).
    private(set) var completedShort = 0
    var forceNextLong = false

    func nextIsLong(every: Int) -> Bool {
        forceNextLong || completedShort >= every - 1
    }

    // Only breaks that ran their course count; skipping never calls this.
    mutating func breakCompleted(long: Bool) {
        if long {
            reset()
        } else {
            completedShort += 1
        }
    }

    // Time away from the screen at least as long as a long break is as good as one.
    mutating func creditAway(_ seconds: TimeInterval, longDuration: TimeInterval) {
        if seconds >= longDuration { reset() }
    }

    mutating func reset() {
        completedShort = 0
        forceNextLong = false
    }
}
