import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    let store = RecordingStore()
    let recorder = AudioRecorder()
    let transcriber = TranscriptionService()

    @Published var selectedRecordingID: Recording.ID?
    @Published var settingsOpenRequest = UUID()
    @Published var newRecordingRequest: UUID?

    @Published var pipelineErrors: [UUID: String] = [:]

    @AppStorage("anthropicModel") var anthropicModel: String = AnthropicService.defaultModel

    private var cancellables: Set<AnyCancellable> = []

    init() {
        // Republish nested ObservableObject changes so views observing AppState
        // re-render when the recorder/transcriber/store update.
        store.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        recorder.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        transcriber.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        GlobalHotkeyService.shared.onToggleRecording = { [weak self] in
            self?.toggleRecording()
        }
    }

    func toggleRecording() {
        if recorder.isRecording {
            if let r = selectedRecording { stopRecordingAndProcess(r) }
        } else {
            requestNewRecording()
        }
    }

    var selectedRecording: Recording? {
        guard let id = selectedRecordingID else { return nil }
        return store.recordings.first { $0.id == id }
    }

    func requestNewRecording() {
        newRecordingRequest = UUID()
    }

    // MARK: - Pipeline

    func startNewRecording() throws -> Recording {
        let url = store.newAudioURL()
        try recorder.start(writingTo: url)
        let recording = Recording(
            title: Self.suggestedTitle(for: Date()),
            audioFilename: url.lastPathComponent,
            status: .recording
        )
        store.upsert(recording)
        selectedRecordingID = recording.id
        return recording
    }

    func stopRecordingAndProcess(_ recording: Recording) {
        let stoppedURL = recorder.stop()
        var updated = recording
        updated.duration = recorder.elapsed
        if stoppedURL == nil {
            updated.status = .failed
            updated.lastError = "Recorder produced no audio file"
            store.upsert(updated)
            return
        }
        updated.status = .transcribing
        store.upsert(updated)
        runPipeline(for: updated.id)
    }

    func retry(_ recording: Recording) {
        var updated = recording
        updated.lastError = nil
        if updated.transcript.isEmpty {
            updated.status = .transcribing
        } else if updated.summaryMarkdown.isEmpty {
            updated.status = .summarizing
        } else {
            updated.status = .ready
        }
        store.upsert(updated)
        runPipeline(for: updated.id)
    }

    private func runPipeline(for id: Recording.ID) {
        Task { [weak self] in
            await self?.executePipeline(id: id)
        }
    }

    private func executePipeline(id: Recording.ID) async {
        guard var recording = store.recordings.first(where: { $0.id == id }) else { return }

        // Transcribe
        if recording.transcript.isEmpty {
            do {
                recording.status = .transcribing
                store.upsert(recording)
                let audioURL = store.audioURL(for: recording)
                let transcript = try await transcriber.transcribe(fileAt: audioURL)
                recording.transcript = transcript
                store.upsert(recording)
            } catch {
                recording.status = .failed
                recording.lastError = "Transcription failed: \(error.localizedDescription)"
                store.upsert(recording)
                return
            }
        }

        // Summarize
        if recording.summaryMarkdown.isEmpty {
            do {
                recording.status = .summarizing
                store.upsert(recording)
                let anthropic = try AnthropicService.makeFromKeychain(model: anthropicModel)
                // Don't pass the placeholder "Recording — date" title as a suggestion —
                // Claude tends to reuse it verbatim instead of inventing a real title.
                let summaryOnly = try await anthropic.summarize(
                    transcript: recording.transcript,
                    suggestedTitle: nil
                )
                let combined = """
                \(summaryOnly.trimmingCharacters(in: .whitespacesAndNewlines))

                ---

                ## Raw transcript

                \(recording.transcript)
                """
                recording.summaryMarkdown = combined
                if let extracted = Self.extractTitle(from: summaryOnly), !extracted.isEmpty {
                    recording.title = extracted
                }
                recording.status = .ready
                store.upsert(recording)
            } catch {
                recording.status = .failed
                recording.lastError = "Summarization failed: \(error.localizedDescription)"
                store.upsert(recording)
                return
            }
        } else {
            recording.status = .ready
            store.upsert(recording)
        }
    }

    static func suggestedTitle(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, yyyy 'at' h:mma"
        return "Recording — \(formatter.string(from: date))"
    }

    static func extractTitle(from markdown: String) -> String? {
        for line in markdown.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
