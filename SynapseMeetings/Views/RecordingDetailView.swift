import SwiftUI

struct RecordingDetailView: View {
    @EnvironmentObject var app: AppState
    let recording: Recording

    @State private var editedMarkdown: String = ""
    @State private var showRawTranscript: Bool = false
    @State private var didLoadInitial = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(minWidth: 460)
        .background(.background)
        .onAppear { loadEdits() }
        .onChange(of: recording.id) { _, _ in loadEdits() }
        .onChange(of: recording.summaryMarkdown) { _, _ in
            // If pipeline updates the summary, refresh the editor
            if recording.summaryMarkdown != editedMarkdown {
                editedMarkdown = recording.summaryMarkdown
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            statusBadge
            Text(recording.title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
            Spacer()
            if recording.status == .ready || recording.status == .committed {
                Button {
                    saveEdits()
                } label: {
                    Label("Save", systemImage: "checkmark.circle")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(editedMarkdown == recording.summaryMarkdown)
            }
            if recording.status == .failed {
                Button {
                    app.retry(recording)
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.background)
    }

    @ViewBuilder
    private var content: some View {
        switch recording.status {
        case .recording:
            RecordingInProgressView(recording: recording)
        case .transcribing:
            ProcessingView(message: "Transcribing with Parakeet…", systemImage: "waveform.badge.magnifyingglass")
        case .summarizing:
            ProcessingView(message: "Summarizing with Claude…", systemImage: "sparkles")
        case .failed:
            FailureView(error: recording.lastError ?? "Unknown error")
        case .ready, .committed:
            editor
        }
    }

    private var editor: some View {
        TextEditor(text: $editedMarkdown)
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .scrollContentBackground(.hidden)
            .background(.background)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch recording.status {
        case .recording:
            Label("Recording", systemImage: "record.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.red)
        case .transcribing:
            Label("Transcribing", systemImage: "waveform")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        case .summarizing:
            Label("Summarizing", systemImage: "sparkles")
                .font(.caption.weight(.medium))
                .foregroundStyle(.purple)
        case .ready:
            Label("Ready", systemImage: "checkmark.circle")
                .font(.caption.weight(.medium))
                .foregroundStyle(.blue)
        case .committed:
            Label("Committed", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.green)
        case .failed:
            Label("Failed", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.orange)
        }
    }

    private func loadEdits() {
        guard !didLoadInitial || recording.summaryMarkdown != editedMarkdown else { return }
        editedMarkdown = recording.summaryMarkdown
        didLoadInitial = true
    }

    private func saveEdits() {
        var updated = recording
        updated.summaryMarkdown = editedMarkdown
        if let title = AppState.extractTitle(from: editedMarkdown) {
            updated.title = title
        }
        app.store.upsert(updated)
    }
}

private struct RecordingInProgressView: View {
    @EnvironmentObject var app: AppState
    let recording: Recording

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(.red.opacity(0.15), lineWidth: 18)
                    .frame(width: 180, height: 180)
                Circle()
                    .stroke(.red.opacity(0.35), lineWidth: 4)
                    .frame(width: 180, height: 180)
                    .scaleEffect(1 + CGFloat(app.recorder.level) * 0.25)
                    .animation(.easeOut(duration: 0.15), value: app.recorder.level)
                Image(systemName: "mic.fill")
                    .font(.system(size: 56, weight: .semibold))
                    .foregroundStyle(.red)
            }
            Text(formattedElapsed(app.recorder.elapsed))
                .font(.system(size: 36, weight: .semibold, design: .monospaced))
                .monospacedDigit()
            Text("Recording in progress — hit Stop in the toolbar when you're done.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func formattedElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

private struct ProcessingView: View {
    let message: String
    let systemImage: String

    var body: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            ProgressView()
                .controlSize(.large)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailureView: View {
    let error: String
    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 36))
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(.headline)
            Text(error)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
