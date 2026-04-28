import SwiftUI

struct AttendeesSidebarView: View {
    @EnvironmentObject var app: AppState
    let recordingID: Recording.ID
    @Binding var attendees: [Attendee]

    @State private var filter: String = ""
    @FocusState private var filterFocused: Bool

    private var trimmedFilter: String {
        filter.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The full set of names shown in the picker: every recorded attendee
    /// (in their stored order) plus any global recent that isn't already on
    /// the recording — recents appended at the bottom, deduped case-insensitively.
    private var displayNames: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for a in attendees {
            let key = a.name.lowercased()
            if seen.insert(key).inserted {
                out.append(a.name)
            }
        }
        for name in app.recentAttendees {
            let key = name.lowercased()
            if seen.insert(key).inserted {
                out.append(name)
            }
        }
        return out
    }

    private var filteredNames: [String] {
        guard !trimmedFilter.isEmpty else { return displayNames }
        let needle = trimmedFilter.lowercased()
        return displayNames.filter { $0.lowercased().contains(needle) }
    }

    private var canAddTyped: Bool {
        guard !trimmedFilter.isEmpty else { return false }
        let key = trimmedFilter.lowercased()
        return !displayNames.contains { $0.lowercased() == key }
    }

    private var selectedCount: Int {
        attendees.filter { $0.selected }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            filterField
            Divider()
            list
        }
        .frame(minWidth: 180, idealWidth: 220, maxWidth: 260)
        .background(.background)
        .onChange(of: attendees) { _, _ in
            app.updateAttendees(for: recordingID, attendees: attendees)
        }
    }

    private var header: some View {
        HStack {
            Label("Attendees", systemImage: "person.2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            Spacer()
            if selectedCount > 0 {
                Text("\(selectedCount) selected")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.tertiary)
            TextField("Add or filter…", text: $filter)
                .textFieldStyle(.plain)
                .font(.callout)
                .focused($filterFocused)
                .onSubmit { commitTypedAttendee() }
            if !filter.isEmpty {
                Button {
                    filter = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var list: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                if displayNames.isEmpty && trimmedFilter.isEmpty {
                    emptyState
                } else {
                    ForEach(filteredNames, id: \.self) { name in
                        AttendeeRow(
                            name: name,
                            selected: bindingForSelection(of: name),
                            onRename: { newName in rename(name, to: newName) },
                            onDelete: { remove(name) }
                        )
                    }

                    if canAddTyped {
                        addRow(label: "Add \"\(trimmedFilter)\"") {
                            commitTypedAttendee()
                        }
                    }
                }
            }
            .padding(.vertical, 6)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No attendees yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Type a name and press Return to add.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
    }

    private func addRow(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "plus.circle")
                    .font(.callout)
                    .foregroundStyle(Color.accentColor)
                Text(label)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Mutations

    private func bindingForSelection(of name: String) -> Binding<Bool> {
        Binding(
            get: {
                attendees.first(where: { $0.name.lowercased() == name.lowercased() })?.selected ?? false
            },
            set: { newValue in
                if let idx = attendees.firstIndex(where: { $0.name.lowercased() == name.lowercased() }) {
                    attendees[idx].selected = newValue
                } else if newValue {
                    // Promoting a recents-only name into the recording.
                    attendees.append(Attendee(name: name, selected: true))
                }
            }
        )
    }

    private func commitTypedAttendee() {
        let name = trimmedFilter
        guard !name.isEmpty else { return }
        let key = name.lowercased()
        if let idx = attendees.firstIndex(where: { $0.name.lowercased() == key }) {
            // Already on the recording — just ensure it's checked.
            if !attendees[idx].selected {
                attendees[idx].selected = true
            }
        } else {
            attendees.append(Attendee(name: name, selected: true))
            // Only Return-adds promote to global recents.
            app.rememberRecentAttendee(name)
        }
        filter = ""
        filterFocused = true
    }

    private func rename(_ oldName: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != oldName else { return }
        if let idx = attendees.firstIndex(where: { $0.name.lowercased() == oldName.lowercased() }) {
            attendees[idx].name = trimmed
        } else {
            // Renaming a recents-only entry — materialize it into the recording, unselected.
            attendees.append(Attendee(name: trimmed, selected: false))
        }
    }

    private func remove(_ name: String) {
        attendees.removeAll { $0.name.lowercased() == name.lowercased() }
    }
}

private struct AttendeeRow: View {
    let name: String
    @Binding var selected: Bool
    let onRename: (String) -> Void
    let onDelete: () -> Void

    @State private var isHovering = false
    @State private var isEditing = false
    @State private var draftName: String = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $selected)
                .toggleStyle(.checkbox)
                .labelsHidden()

            if isEditing {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .focused($nameFocused)
                    .onSubmit { commitEdit() }
                    .onExitCommand { cancelEdit() }
            } else {
                Text(name)
                    .font(.callout)
                    .lineLimit(1)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .onTapGesture(count: 2) { startEdit() }
            }

            Spacer(minLength: 4)

            if isHovering && !isEditing {
                Button(action: onDelete) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Remove from list")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
    }

    private func startEdit() {
        draftName = name
        isEditing = true
        nameFocused = true
    }

    private func commitEdit() {
        onRename(draftName)
        isEditing = false
    }

    private func cancelEdit() {
        isEditing = false
    }
}
