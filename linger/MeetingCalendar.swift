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

// The calendar is linger's only source for meetings: breaks wait while one is on, and the heads-up
// can hold a break until one ends. Optional, and limited to the account and calendar the user picks.
@Observable
final class MeetingCalendar {
    enum Status { case off, allowed, needsAccount, denied }

    struct Account: Identifiable, Hashable {
        let id: String
        let title: String
    }

    struct CalendarChoice: Identifiable, Hashable {
        let id: String
        let title: String
    }

    static let shared = MeetingCalendar()

    static let privacyPane = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    // How far ahead a meeting still counts as "the one you're about to be in".
    private static let lookahead: TimeInterval = 10 * 60
    // Longer blocks are focus time or travel, not meetings; they shouldn't switch breaks off.
    private static let longestMeeting: TimeInterval = 3 * 60 * 60

    private(set) var isOn: Bool {
        didSet { UserDefaults.standard.set(isOn, forKey: DefaultsKey.calendarOn) }
    }
    private(set) var status: Status = .off
    private(set) var accounts: [Account] = []
    // True while macOS shows its access prompt; full-screen surfaces step aside for it.
    private(set) var isRequestingAccess = false

    // The email account (an EventKit source) to read; nil until chosen, unless there is only one.
    var accountID: String? {
        didSet {
            UserDefaults.standard.set(accountID, forKey: DefaultsKey.calendarAccount)
            if oldValue != accountID { calendarID = nil }
            refresh()
        }
    }

    // One calendar in that account, or nil for all of them.
    var calendarID: String? {
        didSet { UserDefaults.standard.set(calendarID, forKey: DefaultsKey.calendarID) }
    }

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    private init() {
        let defaults = UserDefaults.standard
        isOn = defaults.bool(forKey: DefaultsKey.calendarOn)
        accountID = defaults.string(forKey: DefaultsKey.calendarAccount)
        calendarID = defaults.string(forKey: DefaultsKey.calendarID)
        // Access may have been granted or revoked in System Settings while we were in the background,
        // and accounts come and go in Internet Accounts.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        })
        refresh()
    }

    var canRead: Bool { status == .allowed }

    var accountTitle: String? { accounts.first { $0.id == accountID }?.title }

    func calendars(in accountID: String) -> [CalendarChoice] {
        eventCalendars(in: accountID).map { CalendarChoice(id: $0.calendarIdentifier, title: $0.title) }
    }

    func refresh() {
        let access = EKEventStore.authorizationStatus(for: .event)
        if access == .fullAccess {
            accounts = Dictionary(grouping: store.calendars(for: .event), by: \.source.sourceIdentifier)
                .compactMap { id, calendars in calendars.first.map { Account(id: id, title: $0.source.title) } }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            // Nothing to ask when there's a single account; a vanished account has to be chosen again.
            if accounts.count == 1, accountID == nil {
                accountID = accounts[0].id
                return
            }
            if let accountID, !accounts.contains(where: { $0.id == accountID }) {
                self.accountID = nil
                return
            }
        } else {
            accounts = []
        }

        status = switch access {
        case .fullAccess where !isOn: .off
        case .fullAccess: accountID == nil ? .needsAccount : .allowed
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
        isRequestingAccess = true
        Task {
            defer { isRequestingAccess = false }
            do {
                let granted = try await store.requestFullAccessToEvents()
                log.debug("Calendar access \(granted ? "granted" : "declined")")
            } catch {
                log.error("Calendar access request failed: \(error.localizedDescription)")
            }
            refresh()
        }
    }

    // The meeting on right now; breaks wait until it ends.
    func meetingInProgress(now: Date = Date()) -> CalendarMeeting? {
        meetings(from: now, to: now.addingTimeInterval(1)).first { $0.start <= now }
    }

    // The meeting in progress, or else the next one starting within a few minutes.
    func currentMeeting(now: Date = Date()) -> CalendarMeeting? {
        let candidates = meetings(from: now, to: now.addingTimeInterval(Self.lookahead))
        let inProgress = candidates.filter { $0.start <= now }.min { $0.end < $1.end }
        return inProgress ?? candidates.min { $0.start < $1.start }
    }

    private func meetings(from start: Date, to end: Date) -> [CalendarMeeting] {
        guard canRead, let accountID else { return [] }
        let calendars = eventCalendars(in: accountID).filter { calendarID == nil || $0.calendarIdentifier == calendarID }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).compactMap { event in
            guard !event.isAllDay, event.status != .canceled, event.availability != .free,
                  event.endDate > start,
                  event.endDate.timeIntervalSince(event.startDate) <= Self.longestMeeting
            else { return nil }
            let declined = event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
            guard !declined else { return nil }
            let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return CalendarMeeting(title: title.isEmpty ? "Untitled meeting" : title, start: event.startDate, end: event.endDate)
        }
    }

    private func eventCalendars(in accountID: String) -> [EKCalendar] {
        store.calendars(for: .event)
            .filter { $0.source.sourceIdentifier == accountID }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
}
