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
            TranscribingView(message: "Transcribing with Parakeet…")
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

    @State private var notesDraft: String = ""

    var body: some View {
        VStack(spacing: 0) {
            // Top bar: waveform + timer
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(.red.opacity(0.15), lineWidth: 6)
                        .frame(width: 48, height: 48)
                    Circle()
                        .stroke(.red.opacity(0.4), lineWidth: 2)
                        .frame(width: 48, height: 48)
                        .scaleEffect(1 + CGFloat(app.recorder.level) * 0.25)
                        .animation(.easeOut(duration: 0.15), value: app.recorder.level)
                    Image(systemName: "mic.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.red)
                }
                Text(formattedElapsed(app.recorder.elapsed))
                    .font(.system(size: 22, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                Spacer()
                Text("Stop recording when done")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            // Live transcript (top half)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Live transcript", systemImage: "waveform")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            if app.liveTranscript.isEmpty {
                                Text("Transcription will appear here as you speak…")
                                    .font(.callout)
                                    .foregroundStyle(.tertiary)
                                    .padding(16)
                            } else {
                                Text(app.liveTranscript)
                                    .font(.system(.body, design: .default))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id("transcript")
                            }
                        }
                    }
                    .onChange(of: app.liveTranscript) { _, _ in
                        withAnimation { proxy.scrollTo("transcript", anchor: .bottom) }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            // Notes editor (bottom half)
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Label("Your notes", systemImage: "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Spacer()
                    Text("Saved automatically — included in the summary")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 4)

                TextEditor(text: $notesDraft)
                    .font(.system(.body, design: .default))
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .scrollContentBackground(.hidden)
                    .background(.background)
                    .onChange(of: notesDraft) { _, newValue in
                        app.updateLiveNotes(for: recording.id, notes: newValue)
                    }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { notesDraft = recording.liveNotes }
    }

    private func formattedElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}

private struct TranscribingView: View {
    @EnvironmentObject var app: AppState
    let message: String

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if app.liveTranscript.isEmpty {
                        ProcessingView(message: message, systemImage: "waveform.badge.magnifyingglass")
                    } else {
                        Text(app.liveTranscript)
                            .font(.system(.body, design: .default))
                            .foregroundStyle(.primary)
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
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
