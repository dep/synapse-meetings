import Foundation
import EventKit
import Combine
import AppKit

@MainActor
final class CalendarService: ObservableObject {
    enum AuthState: Equatable {
        case notDetermined
        case denied
        case restricted
        case granted
    }

    @Published private(set) var authState: AuthState = .notDetermined
    @Published private(set) var calendars: [EKCalendar] = []
    @Published private(set) var eventsForSelectedDay: [EKEvent] = []
    @Published var selectedDate: Date = Calendar.current.startOfDay(for: Date()) {
        didSet { reloadEvents() }
    }

    /// IDs (calendarIdentifier) the user has chosen to hide. Persisted as JSON in UserDefaults.
    @Published private(set) var hiddenCalendarIDs: Set<String> = []

    private static let hiddenCalendarsKey = "hiddenCalendarIDs"

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?

    init() {
        loadHiddenCalendarIDs()
        refreshAuthState()
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.reloadCalendars()
                self?.reloadEvents()
            }
        }
    }

    deinit {
        if let changeObserver {
            NotificationCenter.default.removeObserver(changeObserver)
        }
    }

    // MARK: - Permission

    func refreshAuthState() {
        let raw = EKEventStore.authorizationStatus(for: .event)
        authState = mapStatus(raw)
        if authState == .granted {
            reloadCalendars()
            reloadEvents()
        }
    }

    /// Requests calendar access. macOS 14+ uses requestFullAccessToEvents; older fall back to requestAccess.
    func requestAccess() async {
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await store.requestAccess(to: .event)
            }
            authState = granted ? .granted : .denied
            if granted {
                reloadCalendars()
                reloadEvents()
            }
        } catch {
            NSLog("Calendar access request failed: \(error)")
            authState = .denied
        }
    }

    func openSystemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Data

    private func reloadCalendars() {
        guard authState == .granted else {
            calendars = []
            return
        }
        let cals = store.calendars(for: .event)
            .sorted { lhs, rhs in
                let lSrc = lhs.source.title
                let rSrc = rhs.source.title
                if lSrc != rSrc { return lSrc < rSrc }
                return lhs.title < rhs.title
            }
        calendars = cals
    }

    private func reloadEvents() {
        guard authState == .granted else {
            eventsForSelectedDay = []
            return
        }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: selectedDate)
        guard let dayEnd = cal.date(byAdding: .day, value: 1, to: dayStart) else { return }

        let visible = visibleCalendars()
        guard !visible.isEmpty else {
            eventsForSelectedDay = []
            return
        }

        let predicate = store.predicateForEvents(withStart: dayStart, end: dayEnd, calendars: visible)
        let events = store.events(matching: predicate)
            .sorted { ($0.startDate ?? .distantPast) < ($1.startDate ?? .distantPast) }
        eventsForSelectedDay = events
    }

    /// Force a reload — used after toggling a calendar's visibility.
    func reloadAll() {
        reloadCalendars()
        reloadEvents()
    }

    /// Calendars the user wants visible. Default is all of them.
    func visibleCalendars() -> [EKCalendar] {
        calendars.filter { !hiddenCalendarIDs.contains($0.calendarIdentifier) }
    }

    func isVisible(_ calendar: EKCalendar) -> Bool {
        !hiddenCalendarIDs.contains(calendar.calendarIdentifier)
    }

    func setVisible(_ calendar: EKCalendar, visible: Bool) {
        if visible {
            hiddenCalendarIDs.remove(calendar.calendarIdentifier)
        } else {
            hiddenCalendarIDs.insert(calendar.calendarIdentifier)
        }
        persistHiddenCalendarIDs()
        reloadEvents()
    }

    // MARK: - Persistence

    private func loadHiddenCalendarIDs() {
        if let arr = UserDefaults.standard.stringArray(forKey: Self.hiddenCalendarsKey) {
            hiddenCalendarIDs = Set(arr)
        }
    }

    private func persistHiddenCalendarIDs() {
        UserDefaults.standard.set(Array(hiddenCalendarIDs), forKey: Self.hiddenCalendarsKey)
    }

    // MARK: - Helpers

    private func mapStatus(_ status: EKAuthorizationStatus) -> AuthState {
        // Pre-macOS-14 enum: .notDetermined=0, .restricted=1, .denied=2, .authorized=3
        // macOS 14+ adds: .writeOnly=4, .fullAccess=5 (and .authorized is deprecated but still =3).
        // Using rawValue avoids referring to symbols that may not exist on the SDK.
        switch status.rawValue {
        case 0: return .notDetermined
        case 1: return .restricted
        case 2: return .denied
        case 3: return .granted // legacy .authorized
        case 4: return .denied  // .writeOnly — we need read access
        case 5: return .granted // .fullAccess
        default: return .notDetermined
        }
    }
}

extension EKEvent {
    /// Pulls likely-attendee names off the event. Falls back to email local-part when no display name.
    var inferredAttendeeNames: [String] {
        var names: [String] = []
        if let organizer = organizer, let n = personDisplayName(from: organizer) {
            names.append(n)
        }
        if let participants = attendees {
            for p in participants {
                if let n = personDisplayName(from: p), !names.contains(where: { $0.caseInsensitiveCompare(n) == .orderedSame }) {
                    names.append(n)
                }
            }
        }
        return names
    }

    private func personDisplayName(from participant: EKParticipant) -> String? {
        if let name = participant.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        // Fall back to the email local-part — EKParticipant exposes the URL as `mailto:foo@bar`.
        let urlString = participant.url.absoluteString
        if let scheme = participant.url.scheme, scheme.lowercased() == "mailto" {
            let email = String(urlString.dropFirst("mailto:".count))
            if let at = email.firstIndex(of: "@") {
                let local = String(email[..<at])
                if !local.isEmpty { return local }
            }
        }
        return nil
    }
}
