import SwiftUI
import EventKit

struct CalendarSidebarView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            switch app.calendar.authState {
            case .granted:
                grantedContent
            case .notDetermined:
                pendingContent
            case .denied, .restricted:
                deniedContent
            }
        }
        .background(.background)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Label("Calendar", systemImage: "calendar")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            if app.calendar.authState == .granted {
                Button("Today") {
                    app.calendar.selectedDate = Calendar.current.startOfDay(for: Date())
                }
                .font(.caption)
                .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var grantedContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            MiniCalendarGrid(
                selectedDate: Binding(
                    get: { app.calendar.selectedDate },
                    set: { app.calendar.selectedDate = Calendar.current.startOfDay(for: $0) }
                )
            )
            .padding(.horizontal, 10)
            .padding(.top, 8)
            .padding(.bottom, 12)

            Divider()

            DayEventsList()
        }
    }

    private var pendingContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect your calendar to see today's events here.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Allow Calendar Access") {
                Task { await app.calendar.requestAccess() }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private var deniedContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calendar access is off.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Enable it in System Settings → Privacy & Security → Calendars.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") {
                app.calendar.openSystemSettings()
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }
}

// MARK: - Mini calendar grid

private struct MiniCalendarGrid: View {
    @Binding var selectedDate: Date

    @State private var displayedMonth: Date = Calendar.current.startOfDay(for: Date())

    private var calendar: Calendar { Calendar.current }

    private var monthTitle: String {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f.string(from: displayedMonth)
    }

    private var weekdaySymbols: [String] {
        let f = DateFormatter()
        // veryShortStandaloneWeekdaySymbols rotated by current locale's first weekday.
        let symbols = f.veryShortStandaloneWeekdaySymbols ?? ["S","M","T","W","T","F","S"]
        let firstWeekday = calendar.firstWeekday // 1 = Sunday
        let offset = firstWeekday - 1
        return Array(symbols[offset...] + symbols[..<offset])
    }

    /// 6 weeks * 7 days = 42 cells, with leading/trailing days from adjacent months.
    private var dayCells: [DayCell] {
        guard let interval = calendar.dateInterval(of: .month, for: displayedMonth),
              let firstWeekday = calendar.dateComponents([.weekday], from: interval.start).weekday else {
            return []
        }
        let leading = (firstWeekday - calendar.firstWeekday + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leading, to: interval.start)!
        return (0..<42).map { offset in
            let date = calendar.date(byAdding: .day, value: offset, to: gridStart)!
            let inMonth = calendar.isDate(date, equalTo: displayedMonth, toGranularity: .month)
            return DayCell(date: date, inMonth: inMonth)
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Button { shiftMonth(by: -1) } label: {
                    Image(systemName: "chevron.left").font(.caption)
                }
                .buttonStyle(.borderless)
                Spacer()
                Text(monthTitle)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button { shiftMonth(by: 1) } label: {
                    Image(systemName: "chevron.right").font(.caption)
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { sym in
                    Text(sym)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(dayCells) { cell in
                    dayButton(for: cell)
                }
            }
        }
        .onAppear {
            displayedMonth = startOfMonth(selectedDate)
        }
        .onChange(of: selectedDate) { _, newValue in
            // Keep the displayed month in sync if the selection moved to another month.
            if !calendar.isDate(newValue, equalTo: displayedMonth, toGranularity: .month) {
                displayedMonth = startOfMonth(newValue)
            }
        }
    }

    private func dayButton(for cell: DayCell) -> some View {
        let isToday = calendar.isDateInToday(cell.date)
        let isSelected = calendar.isDate(cell.date, inSameDayAs: selectedDate)
        let day = calendar.component(.day, from: cell.date)

        return Button {
            selectedDate = calendar.startOfDay(for: cell.date)
        } label: {
            Text("\(day)")
                .font(.system(size: 11, weight: isToday ? .semibold : .regular))
                .frame(maxWidth: .infinity, minHeight: 22)
                .foregroundStyle(foreground(isSelected: isSelected, isToday: isToday, inMonth: cell.inMonth))
                .background(background(isSelected: isSelected, isToday: isToday))
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func foreground(isSelected: Bool, isToday: Bool, inMonth: Bool) -> Color {
        if isSelected { return .white }
        if !inMonth { return .secondary.opacity(0.5) }
        if isToday { return Color.accentColor }
        return .primary
    }

    private func background(isSelected: Bool, isToday: Bool) -> some View {
        Group {
            if isSelected {
                Color.accentColor
            } else if isToday {
                Color.accentColor.opacity(0.12)
            } else {
                Color.clear
            }
        }
    }

    private func shiftMonth(by months: Int) {
        if let next = calendar.date(byAdding: .month, value: months, to: displayedMonth) {
            displayedMonth = startOfMonth(next)
        }
    }

    private func startOfMonth(_ date: Date) -> Date {
        let comps = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: comps) ?? date
    }
}

private struct DayCell: Identifiable {
    let date: Date
    let inMonth: Bool
    var id: TimeInterval { date.timeIntervalSinceReferenceDate }
}

// MARK: - Day events

private struct DayEventsList: View {
    @EnvironmentObject var app: AppState

    /// Re-evaluated every minute so past events fade as time passes without reopening the sidebar.
    @State private var now: Date = Date()
    private let tickTimer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private var dateLabel: String {
        let f = DateFormatter()
        f.dateStyle = .medium
        return f.string(from: app.calendar.selectedDate)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(dateLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if app.calendar.eventsForSelectedDay.isEmpty {
                Text("No events on this day.")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(app.calendar.eventsForSelectedDay, id: \.eventIdentifier) { event in
                            EventRow(event: event, now: now) {
                                startRecording(for: event)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .onReceive(tickTimer) { now = $0 }
    }

    private func startRecording(for event: EKEvent) {
        let title = event.title
        let attendees: [Attendee]
        if app.prefillAttendeesFromCalendar {
            attendees = event.inferredAttendeeNames.map { Attendee(name: $0, selected: true) }
        } else {
            attendees = []
        }
        app.requestNewRecording(prefilledTitle: title, prefilledAttendees: attendees)
    }
}

private struct EventRow: View {
    let event: EKEvent
    let now: Date
    let onRecord: () -> Void

    @State private var isHovering = false

    private var timeLabel: String {
        if event.isAllDay { return "All day" }
        let f = DateFormatter()
        f.timeStyle = .short
        let start = event.startDate.map { f.string(from: $0) } ?? "—"
        let end = event.endDate.map { f.string(from: $0) } ?? ""
        return end.isEmpty ? start : "\(start)–\(end)"
    }

    private var color: Color {
        if let cg = event.calendar?.cgColor {
            return Color(cgColor: cg)
        }
        return .accentColor
    }

    /// True when the event has already ended (and isn't all-day). Past events
    /// are dimmed so the user's eye lands on what's current/upcoming.
    private var isPast: Bool {
        guard !event.isAllDay, let end = event.endDate else { return false }
        return end < now
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Rectangle()
                .fill(color)
                .frame(width: 3)
                .frame(maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 1.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(event.title ?? "(Untitled)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                Text(timeLabel)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button(action: onRecord) {
                Image(systemName: "record.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
            .help("Start a recording for this event")
        }
        .opacity(isPast ? 0.45 : 1.0)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isHovering ? Color.secondary.opacity(0.08) : Color.clear)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }
}
