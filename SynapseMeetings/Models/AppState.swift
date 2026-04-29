import Foundation
import SwiftUI
import Combine
import FluidAudio

@MainActor
final class AppState: ObservableObject {
    let store = RecordingStore()
    let recorder = AudioRecorder()
    let transcriber = TranscriptionService()
    let diarizer = DiarizationService()
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
    @AppStorage("anthropicSystemPrompt") var anthropicSystemPrompt: String = ""
    @AppStorage("anthropicUserPromptTemplate") var anthropicUserPromptTemplate: String = ""
    @AppStorage("prefillAttendeesFromCalendar") var prefillAttendeesFromCalendar: Bool = false
    @AppStorage("audioInputDeviceUID") var audioInputDeviceUID: String = ""
    @AppStorage("diarizationEnabled") var diarizationEnabled: Bool = true

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
        diarizer.objectWillChange
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

        // Pre-warm the diarization model so the first recording's pipeline
        // doesn't pay the download/compile cost in-band.
        Task { [weak self] in
            guard let self else { return }
            if self.diarizationEnabled {
                try? await self.diarizer.ensureLoaded()
            }
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

    /// Create a blank note (no audio, no transcript) and select it. Useful for
    /// jotting things down without the recording pipeline.
    @discardableResult
    func createNewNote() -> Recording {
        let now = Date()
        let title = "Note — \(Self.noteDateFormatter.string(from: now))"
        let starter = "# \(title)\n\n"
        let note = Recording(
            title: title,
            createdAt: now,
            audioFilename: "",
            summaryMarkdown: starter,
            status: .ready
        )
        store.upsert(note)
        selectedRecordingID = note.id
        return note
    }

    private static let noteDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, yyyy 'at' h:mma"
        return f
    }()

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

    /// Re-run the summarization step against the current note content, using
    /// whatever user prompt the user has configured. For recordings, this uses
    /// the saved transcript + live notes. For note-only entries, the current
    /// summary text itself is fed back in as the "transcript" so the AI can
    /// reformat / clean up free-form notes.
    func resummarize(_ recording: Recording) {
        var updated = recording
        if updated.transcript.isEmpty {
            // Note-only: feed the existing summary content back in so we have
            // something for the AI to work with. We must flush the editor's
            // pending edits first so the latest text actually makes it through.
            NotificationCenter.default.post(
                name: .flushPendingEdits,
                object: nil,
                userInfo: ["recordingID": recording.id]
            )
            // Re-fetch after the synchronous flush.
            let latest = store.recordings.first(where: { $0.id == recording.id }) ?? recording
            updated = latest
            let body = latest.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { return }
            updated.transcript = latest.summaryMarkdown
        }
        updated.summaryMarkdown = ""
        updated.lastError = nil
        updated.status = .summarizing
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

        // Transcribe + diarize (in parallel when both are needed)
        if recording.transcript.isEmpty {
            do {
                recording.status = .transcribing
                store.upsert(recording)
                let audioURL = store.audioURL(for: recording)
                let runDiarization = diarizationEnabled

                if runDiarization {
                    // Speaker count hint: number of currently-checked attendees, if any.
                    let hintedSpeakerCount = recording.attendees.filter { $0.selected }.count
                    async let asrTask = transcriber.transcribeWithTimings(fileAt: audioURL)
                    async let diarizeTask: [TimedSpeakerSegment]? = (try? await diarizer.diarize(
                        fileAt: audioURL,
                        numSpeakers: hintedSpeakerCount > 1 ? hintedSpeakerCount : -1
                    ))
                    let asrResult = try await asrTask
                    let segments = await diarizeTask

                    recording.transcript = asrResult.text
                    if let segments, let timings = asrResult.tokenTimings, !timings.isEmpty {
                        recording.speakerTurns = Self.alignTokensToSpeakers(
                            tokens: timings,
                            segments: segments
                        )
                    }
                    store.upsert(recording)
                } else {
                    let transcript = try await transcriber.transcribe(fileAt: audioURL)
                    recording.transcript = transcript
                    store.upsert(recording)
                }
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

                // When we have speaker turns, feed Claude the speaker-labeled version.
                // Otherwise, fall back to the raw transcript.
                let transcriptForClaude: String = recording.speakerTurns.isEmpty
                    ? recording.transcript
                    : Self.formatSpeakerTurns(recording.speakerTurns)

                let summaryOnly = try await anthropic.summarize(
                    transcript: transcriptForClaude,
                    liveNotes: recording.liveNotes,
                    attendees: selectedAttendees,
                    speakerLabeled: !recording.speakerTurns.isEmpty,
                    suggestedTitle: nil,
                    systemPromptOverride: anthropicSystemPrompt,
                    userPromptTemplateOverride: anthropicUserPromptTemplate
                )
                let trimmedNotes = recording.liveNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                let notesSection = trimmedNotes.isEmpty ? "" : """

                ## 📝 Notes taken during meeting

                \(trimmedNotes)

                """
                let transcriptSection = recording.speakerTurns.isEmpty
                    ? recording.transcript
                    : Self.formatSpeakerTurns(recording.speakerTurns)
                let combined = """
                \(summaryOnly.trimmingCharacters(in: .whitespacesAndNewlines))
                \(notesSection)
                ---

                ## Raw transcript

                \(transcriptSection)
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

    // MARK: - Diarization alignment

    /// Walks ASR token timings + diarized speaker segments and produces speaker turns.
    /// Each token's midpoint is bucketed into the speaker segment that contains it
    /// (or the nearest one). Consecutive same-speaker tokens are joined into runs,
    /// with SentencePiece pieces (▁-prefixed) reassembled back into words.
    static func alignTokensToSpeakers(
        tokens: [TokenTiming],
        segments: [TimedSpeakerSegment]
    ) -> [SpeakerTurn] {
        guard !tokens.isEmpty, !segments.isEmpty else { return [] }

        // Stable, presentation-friendly speaker labels: order by first appearance.
        var labelMap: [String: String] = [:]
        var nextSpeakerNumber = 1
        func labelFor(_ rawId: String) -> String {
            if let existing = labelMap[rawId] { return existing }
            let label = "Speaker \(nextSpeakerNumber)"
            nextSpeakerNumber += 1
            labelMap[rawId] = label
            return label
        }

        // Sort segments by start time so the linear walker below stays valid.
        let sortedSegments = segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }

        var turns: [SpeakerTurn] = []
        var currentLabel: String? = nil
        var currentStart: Double = 0
        var currentEnd: Double = 0
        var currentPieces: [String] = []
        var segIdx = 0

        func flushCurrent() {
            guard let label = currentLabel else { return }
            let text = decodePieces(currentPieces)
            if !text.isEmpty {
                turns.append(SpeakerTurn(
                    speakerLabel: label,
                    startSec: currentStart,
                    endSec: currentEnd,
                    text: text
                ))
            }
            currentLabel = nil
            currentPieces.removeAll(keepingCapacity: true)
        }

        for token in tokens {
            let mid = (token.startTime + token.endTime) / 2
            // Advance segment cursor past any segments fully behind us.
            while segIdx + 1 < sortedSegments.count,
                  Double(sortedSegments[segIdx + 1].startTimeSeconds) <= mid {
                segIdx += 1
            }
            let seg = sortedSegments[segIdx]
            let label = labelFor(seg.speakerId)

            if label == currentLabel {
                currentPieces.append(token.token)
                currentEnd = token.endTime
            } else {
                flushCurrent()
                currentLabel = label
                currentStart = token.startTime
                currentEnd = token.endTime
                currentPieces = [token.token]
            }
        }
        flushCurrent()

        return turns
    }

    /// Reassemble SentencePiece tokens (where ▁ marks a word boundary) into normal text.
    private static func decodePieces(_ pieces: [String]) -> String {
        var out = ""
        for piece in pieces {
            if piece.hasPrefix("▁") {
                if !out.isEmpty { out += " " }
                out += String(piece.dropFirst())
            } else {
                out += piece
            }
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// Render speaker turns in `Speaker N: …` format for the saved markdown
    /// and the Claude prompt.
    static func formatSpeakerTurns(_ turns: [SpeakerTurn]) -> String {
        turns.map { "\($0.speakerLabel): \($0.text)" }.joined(separator: "\n\n")
    }
}
