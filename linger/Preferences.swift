import AppKit
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

enum AppAppearance: String, CaseIterable, Identifiable {
    case auto, light, dark

    var id: Self { self }

    static var current: AppAppearance {
        AppAppearance(rawValue: UserDefaults.standard.string(forKey: DefaultsKey.appearance) ?? "") ?? .auto
    }

    func apply() {
        switch self {
        case .auto: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

enum DefaultsKey {
    static let workIntervalSec = "workIntervalSec"
    static let breakDurationSec = "breakDurationSec"
    static let skipDifficulty = "skipDifficulty"
    static let messages = "messages"
    static let breakMessages = "breakMessages"
    static let soundOn = "soundOn"
    static let appearance = "appearance"
    static let menuBarCountdown = "menuBarCountdown"
    static let launchAtLoginOn = "launchAtLoginOn"
    static let calendarOn = "calendarOn"
    static let workHoursOn = "workHoursOn"
    static let workHours = "workHours"
    static let longBreaksOn = "longBreaksOn"
    static let longBreakEvery = "longBreakEvery"
    static let longBreakDurationSec = "longBreakDurationSec"
    static let longBreakMessages = "longBreakMessages"
    static let hasCompletedOnboarding = "hasCompletedOnboarding"

    private static let legacyShowCountdownInMenuBar = "showCountdownInMenuBar"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            workIntervalSec: 20 * 60,
            breakDurationSec: 20,
            skipDifficulty: SkipDifficulty.balanced.rawValue,
            messages: BreakMessages.defaults,
            soundOn: true,
            appearance: AppAppearance.auto.rawValue,
            menuBarCountdown: MenuBarCountdown.minutes.rawValue,
            launchAtLoginOn: true,
            calendarOn: false,
            workHoursOn: false,
            workHours: (try? JSONEncoder().encode(WorkHours.standard)) ?? Data(),
            longBreaksOn: false,
            longBreakEvery: 3,
            longBreakDurationSec: 3 * 60,
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

extension WorkHours {
    static var stored: WorkHours {
        UserDefaults.standard.data(forKey: DefaultsKey.workHours)
            .flatMap { try? JSONDecoder().decode(WorkHours.self, from: $0) } ?? .standard
    }

    func store() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: DefaultsKey.workHours)
    }
}

enum BreakKind {
    case short, long
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

    private static let longDefaults = [
        BreakMessage(title: "Stand up and stretch", subline: "Roll your shoulders and neck"),
        BreakMessage(title: "Walk around for a minute", subline: "Leave the desk, come back when it chimes"),
        BreakMessage(title: "Refill your water", subline: "Look out a window on the way"),
        BreakMessage(title: "Rest your eyes", subline: "Close them, or look at something far away"),
    ]

    private static let fallbackSubline = "Let your eyes rest for a moment"

    static var all: [BreakMessage] { all(.short) }
    static var current: [String] { current(.short) }

    static func all(_ kind: BreakKind) -> [BreakMessage] {
        if kind == .long {
            return UserDefaults.standard.data(forKey: DefaultsKey.longBreakMessages)
                .flatMap { try? JSONDecoder().decode([BreakMessage].self, from: $0) } ?? longDefaults
        }
        if let data = UserDefaults.standard.data(forKey: DefaultsKey.breakMessages),
           let stored = try? JSONDecoder().decode([BreakMessage].self, from: data) {
            return stored
        }
        // First run, or the pre-model `[String]` key.
        let titles = UserDefaults.standard.stringArray(forKey: DefaultsKey.messages) ?? defaults
        return titles.map { BreakMessage(title: $0, subline: defaultSublines[$0] ?? "") }
    }

    static func save(_ messages: [BreakMessage], kind: BreakKind = .short) {
        guard let data = try? JSONEncoder().encode(messages) else { return }
        UserDefaults.standard.set(data, forKey: kind == .long ? DefaultsKey.longBreakMessages : DefaultsKey.breakMessages)
    }

    static func current(_ kind: BreakKind) -> [String] {
        let cleaned = all(kind).map { $0.title.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if !cleaned.isEmpty { return cleaned }
        return kind == .long ? longDefaults.map(\.title) : defaults
    }

    static func subline(for title: String, kind: BreakKind = .short) -> String {
        let custom = all(kind).first { $0.title.trimmingCharacters(in: .whitespaces) == title }?
            .subline.trimmingCharacters(in: .whitespaces)
        if let custom, !custom.isEmpty { return custom }
        let builtIn = kind == .long ? longDefaults.first { $0.title == title }?.subline : defaultSublines[title]
        return builtIn ?? fallbackSubline
    }
}
