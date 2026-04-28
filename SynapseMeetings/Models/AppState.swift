import Foundation
import SwiftUI
import Combine

@MainActor
final class AppState: ObservableObject {
    let store = RecordingStore()
    let recorder = AudioRecorder()
    let transcriber = TranscriptionService()
    let calendar = CalendarService()
    let audioDevices = AudioDeviceService()

    @Published var selectedRecordingID: Recording.ID?
    @Published var settingsOpenRequest = UUID()
    @Published var newRecordingRequest: UUID?

    @Published var pipelineErrors: [UUID: String] = [:]
    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var recentAttendees: [String] = []

    struct PendingRecordingPrefill {
        var title: String?
        var attendees: [Attendee]
    }
    private var pendingPrefill: PendingRecordingPrefill?

    private var liveTranscriptTask: Task<Void, Never>?
    private var lastChunkTranscriptLength = 0

    private static let recentAttendeesKey = "recentAttendees"
    private static let recentAttendeesLimit = 100

    @AppStorage("anthropicModel") var anthropicModel: String = AnthropicService.defaultModel
    @AppStorage("prefillAttendeesFromCalendar") var prefillAttendeesFromCalendar: Bool = false
    @AppStorage("audioInputDeviceUID") var audioInputDeviceUID: String = ""

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
        calendar.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        GlobalHotkeyService.shared.onToggleRecording = { [weak self] in
            self?.toggleRecording()
        }

        loadRecentAttendees()

        // Kick off calendar permission early so the sidebar fills in as soon
        // as the user grants access.
        Task { [weak self] in
            await self?.calendar.requestAccess()
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
        pendingPrefill = nil
        newRecordingRequest = UUID()
    }

    /// Begin a new recording pre-filled with metadata from a calendar event.
    /// Pass `attendees` only when the user has opted into calendar-based attendee prefill.
    func requestNewRecording(prefilledTitle: String?, prefilledAttendees: [Attendee] = []) {
        pendingPrefill = PendingRecordingPrefill(title: prefilledTitle, attendees: prefilledAttendees)
        newRecordingRequest = UUID()
    }

    // MARK: - Pipeline

    func startNewRecording() throws -> Recording {
        let url = store.newAudioURL()
        liveTranscript = ""
        lastChunkTranscriptLength = 0
        recorder.onChunk = { [weak self] chunkURL in
            self?.handleChunk(chunkURL)
        }
        recorder.preferredInputDeviceUID = audioInputDeviceUID
        try recorder.start(writingTo: url)

        let prefill = pendingPrefill
        pendingPrefill = nil

        let title = prefill?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (title?.isEmpty == false) ? title! : Self.suggestedTitle(for: Date())

        let recording = Recording(
            title: resolvedTitle,
            audioFilename: url.lastPathComponent,
            status: .recording,
            attendees: prefill?.attendees ?? []
        )
        store.upsert(recording)
        selectedRecordingID = recording.id
        return recording
    }

    private func handleChunk(_ url: URL) {
        liveTranscriptTask?.cancel()
        liveTranscriptTask = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await transcriber.transcribe(fileAt: url)
                try? FileManager.default.removeItem(at: url)
                guard !Task.isCancelled else { return }
                // Each chunk transcribes the full audio so far, so we replace
                // (not append) — that way Parakeet's evolving understanding
                // of context shows up cleanly without duplication artifacts.
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                self.liveTranscript = cleaned
                self.lastChunkTranscriptLength = cleaned.count
            } catch {
                NSLog("Live chunk transcription failed: \(error)")
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    func stopRecordingAndProcess(_ recording: Recording) {
        liveTranscriptTask?.cancel()
        liveTranscriptTask = nil
        recorder.onChunk = nil
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

    func updateLiveNotes(for id: Recording.ID, notes: String) {
        guard var rec = store.recordings.first(where: { $0.id == id }) else { return }
        rec.liveNotes = notes
        store.upsert(rec)
    }

    // MARK: - Attendees

    func updateAttendees(for id: Recording.ID, attendees: [Attendee]) {
        guard var rec = store.recordings.first(where: { $0.id == id }) else { return }
        rec.attendees = attendees
        store.upsert(rec)
    }

    /// Adds a name to the global recents pool. Called only when the user explicitly
    /// types-and-adds a brand-new attendee — not on every check/uncheck.
    func rememberRecentAttendee(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let key = trimmed.lowercased()
        var merged = recentAttendees.filter { $0.lowercased() != key }
        merged.insert(trimmed, at: 0)
        if merged.count > Self.recentAttendeesLimit {
            merged = Array(merged.prefix(Self.recentAttendeesLimit))
        }
        recentAttendees = merged
        UserDefaults.standard.set(merged, forKey: Self.recentAttendeesKey)
    }

    private func loadRecentAttendees() {
        let saved = UserDefaults.standard.stringArray(forKey: Self.recentAttendeesKey) ?? []
        recentAttendees = saved
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
                let selectedAttendees = recording.attendees
                    .filter { $0.selected }
                    .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                let summaryOnly = try await anthropic.summarize(
                    transcript: recording.transcript,
                    liveNotes: recording.liveNotes,
                    attendees: selectedAttendees,
                    suggestedTitle: nil
                )
                let trimmedNotes = recording.liveNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                let notesSection = trimmedNotes.isEmpty ? "" : """

                ## 📝 Notes taken during meeting

                \(trimmedNotes)

                """
                let combined = """
                \(summaryOnly.trimmingCharacters(in: .whitespacesAndNewlines))
                \(notesSection)
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
