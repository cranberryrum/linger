import Foundation

enum SkipDifficulty: String, CaseIterable, Identifiable {
    case casual, balanced, hardcore

    var id: String { rawValue }

    static let balancedDelay: TimeInterval = 5

    func allowsSkip(elapsed: TimeInterval) -> Bool {
        switch self {
        case .casual: true
        case .balanced: elapsed >= Self.balancedDelay
        case .hardcore: false
        }
    }
}

enum DefaultsKey {
    static let workIntervalSec = "workIntervalSec"
    static let breakDurationSec = "breakDurationSec"
    static let skipDifficulty = "skipDifficulty"
    static let messages = "messages"
    static let soundOn = "soundOn"
    static let showCountdownInMenuBar = "showCountdownInMenuBar"
    static let headsUpOn = "headsUpOn"
    static let launchAtLoginOn = "launchAtLoginOn"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            workIntervalSec: 20 * 60,
            breakDurationSec: 20,
            skipDifficulty: SkipDifficulty.balanced.rawValue,
            messages: BreakMessages.defaults,
            soundOn: true,
            showCountdownInMenuBar: true,
            headsUpOn: false,
            launchAtLoginOn: true,
            hasCompletedOnboarding: false,
        ])
    }
}

enum BreakMessages {
    static let defaults = [
        "Look far away",
        "Look out the window",
        "Take a sip of water",
        "Unfocus your eyes",
        "Blink slowly a few times",
    ]

    private static let sublines = [
        "Look far away": "Find the farthest thing you can see",
        "Look out the window": "Let your eyes settle on something distant",
        "Take a sip of water": "Then look up from the screen for a moment",
        "Unfocus your eyes": "Let the room go soft for a moment",
        "Blink slowly a few times": "Give your eyes a moment to rest",
    ]

    static func subline(for message: String) -> String {
        sublines[message] ?? "Let your eyes rest for a moment"
    }

    static var current: [String] {
        let stored = UserDefaults.standard.stringArray(forKey: DefaultsKey.messages) ?? []
        let cleaned = stored.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? defaults : cleaned
    }
}
