import SwiftUI

struct RecordingsListView: View {
    @EnvironmentObject var app: AppState
    @State private var searchDraft: String = ""
    @State private var activeQuery: String = ""

    var body: some View {
        List(selection: Binding(
            get: { app.selectedRecordingID },
            set: { app.selectedRecordingID = $0 }
        )) {
            let visible = filteredRecordings
            if app.store.recordings.isEmpty {
                EmptyListPlaceholder()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if visible.isEmpty {
                NoMatchesPlaceholder(query: activeQuery)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(visible) { recording in
                    RecordingRow(recording: recording)
                        .tag(recording.id as Recording.ID?)
                        .contextMenu {
                            Button("Delete", role: .destructive) {
                                app.store.delete(recording)
                                if app.selectedRecordingID == recording.id {
                                    app.selectedRecordingID = nil
                                }
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    NewRecordingButton()
                    NewNoteButton()
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 6)

                SearchField(text: $searchDraft, onSubmit: {
                    activeQuery = searchDraft.trimmingCharacters(in: .whitespacesAndNewlines)
                }, onClear: {
                    searchDraft = ""
                    activeQuery = ""
                })
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
            .background(.bar)
        }
        .navigationTitle("Recordings")
        .frame(minWidth: 240)
    }

    private var filteredRecordings: [Recording] {
        guard !activeQuery.isEmpty else { return app.store.recordings }
        let needle = activeQuery.lowercased()
        return app.store.recordings.filter { r in
            r.title.lowercased().contains(needle)
                || r.liveNotes.lowercased().contains(needle)
                || r.summaryMarkdown.lowercased().contains(needle)
                || r.transcript.lowercased().contains(needle)
        }
    }
}

private struct SearchField: View {
    @Binding var text: String
    let onSubmit: () -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Search notes", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
        )
    }
}

private struct NoMatchesPlaceholder: View {
    let query: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No matches for “\(query)”")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

private struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                statusIndicator
                Text(recording.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(recording.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if recording.duration > 0 {
                    Text("·")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text(formattedDuration(recording.duration))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if recording.status == .committed {
                    committedBadge
                } else if recording.status != .ready {
                    Text(recording.status.displayLabel)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var committedBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 9, weight: .bold))
            Text("Committed")
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(.green)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(.green.opacity(0.15))
        )
        .overlay(
            Capsule().stroke(.green.opacity(0.4), lineWidth: 0.5)
        )
        .help(committedTooltip)
    }

    private var committedTooltip: String {
        if let repo = recording.committedRepo, let path = recording.committedPath {
            return "Committed to \(repo)/\(path)"
        }
        return "Committed to GitHub"
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch recording.status {
        case .recording:
            Circle().fill(.red).frame(width: 8, height: 8)
        case .transcribing, .summarizing:
            ProgressView().controlSize(.mini).scaleEffect(0.6).frame(width: 8, height: 8)
        case .ready:
            if recording.isNote {
                Image(systemName: "note.text")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.purple)
                    .frame(width: 10, height: 10)
            } else {
                Circle().fill(.blue).frame(width: 8, height: 8)
            }
        case .committed:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 9))
                .foregroundStyle(.orange)
        }
    }

    private func formattedDuration(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return String(format: "%d:%02d", m, s)
    }
}

private struct EmptyListPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "mic.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Nothing here yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("⌘N for a new note · ⌘R to record ✨")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

private struct NewRecordingButton: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if app.recorder.isRecording {
            Button {
                if let r = app.selectedRecording {
                    app.stopRecordingAndProcess(r)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Stop")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .tint(.red)
            .help("Stop recording")
        } else {
            Button {
                app.requestNewRecording()
            } label: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.red)
                        .frame(width: 7, height: 7)
                    Text("Record")
                        .font(.system(size: 12, weight: .semibold))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Start a new recording (⌘R)")
        }
    }
}

private struct NewNoteButton: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Button {
            app.createNewNote()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 10, weight: .semibold))
                Text("Note")
                    .font(.system(size: 12, weight: .semibold))
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(app.recorder.isRecording)
        .help("Create a blank note (⌘N)")
    }
}
