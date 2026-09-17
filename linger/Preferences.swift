import Foundation

enum SkipDifficulty: String, CaseIterable, Identifiable {
    case casual, balanced, hardcore

    var id: String { rawValue }

    static let holdDuration: TimeInterval = 1

    static var current: SkipDifficulty {
        SkipDifficulty(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.skipDifficulty) ?? "") ?? .balanced
    }

    var canSkip: Bool { self != .hardcore }
}

enum MenuBarCountdown: String, CaseIterable, Identifiable {
    case off, minutes, precise

    var id: String { rawValue }

    static var current: MenuBarCountdown {
        MenuBarCountdown(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.menuBarCountdown) ?? "") ?? .minutes
    }
}

enum DefaultsKey {
    static let workIntervalSec = "workIntervalSec"
    static let breakDurationSec = "breakDurationSec"
    static let skipDifficulty = "skipDifficulty"
    static let messages = "messages"
    static let breakMessages = "breakMessages"
    static let soundOn = "soundOn"
    static let menuBarCountdown = "menuBarCountdown"
    static let launchAtLoginOn = "launchAtLoginOn"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"

    private static let legacyShowCountdownInMenuBar = "showCountdownInMenuBar"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            workIntervalSec: 20 * 60,
            breakDurationSec: 20,
            skipDifficulty: SkipDifficulty.balanced.rawValue,
            messages: BreakMessages.defaults,
            soundOn: true,
            menuBarCountdown: MenuBarCountdown.minutes.rawValue,
            launchAtLoginOn: true,
            hasCompletedOnboarding: false,
        ])
        migrate()
    }

    private static func migrate() {
        let defaults = UserDefaults.standard
        if let legacy = defaults.object(forKey: legacyShowCountdownInMenuBar) as? Bool {
            defaults.set((legacy ? MenuBarCountdown.precise : .off).rawValue, forKey: menuBarCountdown)
            defaults.removeObject(forKey: legacyShowCountdownInMenuBar)
        }
    }
}

struct BreakMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var subline = ""
}

enum BreakMessages {
    static let defaults = [
        "Look far away",
        "Look out the window",
        "Take a sip of water",
        "Unfocus your eyes",
        "Blink slowly a few times",
    ]

    private static let defaultSublines = [
        "Look far away": "Find the farthest thing you can see",
        "Look out the window": "Let your eyes settle on something distant",
        "Take a sip of water": "Then look up from the screen for a moment",
        "Unfocus your eyes": "Let the room go soft for a moment",
        "Blink slowly a few times": "Give your eyes a moment to rest",
    ]

    private static let fallbackSubline = "Let your eyes rest for a moment"

    static var all: [BreakMessage] {
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.breakMessages),
           let stored = try? JSONDecoder().decode([BreakMessage].self, from: data) {
            return stored
        }
        // First run, or the pre-model `[String]` key.
        let titles = UserDefaults.standard.stringArray(forKey: DefaultsKey.messages) ?? defaults
        return titles.map { BreakMessage(title: $0, subline: defaultSublines[$0] ?? "") }
    }

    static func save(_ messages: [BreakMessage]) {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.breakMessages)
    }

    static var current: [String] {
        let cleaned = all.map { $0.title.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return cleaned.isEmpty ? defaults : cleaned
    }

    static func subline(for title: String) -> String {
        let custom = all.first { $0.title.trimmingCharacters(in: .whitespaces) == title }?
            .subline.trimmingCharacters(in: .whitespaces)
        if let custom, !custom.isEmpty { return custom }
        return defaultSublines[title] ?? fallbackSubline
    }
}
