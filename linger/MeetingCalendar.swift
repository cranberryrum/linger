import AppKit
import EventKit
import Observation
import os

private let log = Logger(subsystem: "com.adityakolte.linger", category: "calendar")

struct CalendarMeeting: Equatable {
    let title: String
    let start: Date
    let end: Date
}

// Reads the user's calendar so "After meeting" can name the meeting and know when it ends.
// Optional: nothing else in linger needs it, and access is only requested from the toggle.
@Observable
final class MeetingCalendar {
    enum Status { case off, allowed, denied }

    static let shared = MeetingCalendar()

    static let privacyPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    // How far ahead a meeting still counts as "the one you're about to be in".
    private static let lookahead: TimeInterval = 10 * 60

    private(set) var isOn: Bool {
        didSet { UserDefaults.standard.set(isOn, forKey: DefaultsKey.calendarOn) }
    }
    private(set) var status: Status = .off

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    private init() {
        isOn = UserDefaults.standard.bool(forKey: DefaultsKey.calendarOn)
        // Access may have been granted or revoked in System Settings while we were in the background.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
    }

    var canRead: Bool { isOn && status == .allowed }

    func refresh() {
        status = switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: isOn ? .allowed : .off
        case .denied, .restricted, .writeOnly: isOn ? .denied : .off
        default: .off
        }
    }

    func setOn(_ on: Bool) {
        isOn = on
        guard on, EKEventStore.authorizationStatus(for: .event) == .notDetermined else {
            refresh()
            return
        }
        Task {
            do {
                let granted = try await store.requestFullAccessToEvents()
                log.debug("Calendar access \(granted ? "granted" : "declined")")
            } catch {
                log.error("Calendar access request failed: \(error.localizedDescription)")
            }
            refresh()
        }
    }

    // The meeting in progress, or else the next one starting within a few minutes.
    func currentMeeting(now: Date = Date()) -> CalendarMeeting? {
        guard canRead else { return nil }
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(Self.lookahead), calendars: nil)
        let events = store.events(matching: predicate).filter { event in
            guard !event.isAllDay, event.status != .canceled, event.availability != .free,
                  event.endDate > now
            else { return false }
            let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
            return !declined
        }
        let inProgress = events.filter { $0.startDate <= now }.min { $0.endDate < $1.endDate }
        guard let event = inProgress ?? events.min(by: { $0.startDate < $1.startDate }) else { return nil }

        let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return CalendarMeeting(title: title.isEmpty ? "Untitled meeting" : title, start: event.startDate, end: event.endDate)
    }
}
