import SwiftUI

struct RecordingsListView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        List(selection: Binding(
            get: { app.selectedRecordingID },
            set: { app.selectedRecordingID = $0 }
        )) {
            if app.store.recordings.isEmpty {
                EmptyListPlaceholder()
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else {
                ForEach(app.store.recordings) { recording in
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
        .navigationTitle("Recordings")
        .frame(minWidth: 240)
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
            Circle().fill(.blue).frame(width: 8, height: 8)
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
            Text("No recordings yet")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Hit ⌘N to start your first one ✨")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}
