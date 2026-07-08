import Foundation
import SwiftUI
import Combine
import FluidAudio

@MainActor
final class AppState: ObservableObject {
    let store: RecordingStore
    /// Factory seam: tests replace this to avoid Keychain + network.
    private let makeSummarizer: (SummarizerConfig) throws -> any Summarizing
    let recorder = AudioRecorder()
    let transcriber = TranscriptionService()
    let diarizer = DiarizationService()
    let calendar = CalendarService()
    let audioDevices = AudioDeviceService()

    @Published var selectedRecordingID: Recording.ID?
    /// The recording currently capturing audio. Can differ from `selectedRecordingID`
    /// when the user selects another row in the list while recording.
    @Published private(set) var activeRecordingID: Recording.ID?
    @Published var settingsOpenRequest = UUID()

    @Published private(set) var liveTranscript: String = ""
    @Published private(set) var recentAttendees: [String] = []

    struct PendingRecordingPrefill {
        var title: String?
        var attendees: [Attendee]
    }
    private var pendingPrefill: PendingRecordingPrefill?

    private var liveTranscriptTask: Task<Void, Never>?

    private static let recentAttendeesKey = "recentAttendees"
    private static let recentAttendeesLimit = 100

    @AppStorage("llmProvider") var llmProviderRaw: String = LLMProvider.anthropic.rawValue
    @AppStorage("anthropicModel") var anthropicModel: String = AnthropicService.defaultModel
    @AppStorage("openRouterModel") var openRouterModel: String = OpenRouterService.defaultModel
    @AppStorage("anthropicSystemPrompt") var anthropicSystemPrompt: String = ""
    @AppStorage("anthropicUserPromptTemplate") var anthropicUserPromptTemplate: String = ""
    @AppStorage("prefillAttendeesFromCalendar") var prefillAttendeesFromCalendar: Bool = false
    @AppStorage("audioInputDeviceUID") var audioInputDeviceUID: String = ""
    @AppStorage("diarizationEnabled") var diarizationEnabled: Bool = true
    @AppStorage("systemAudioCaptureEnabled") var systemAudioCaptureEnabled: Bool = true

    /// Computed accessor over `llmProviderRaw`. Falls back to Anthropic if a
    /// previously-stored value is no longer recognized.
    /// `@AppStorage` does not publish from an ObservableObject (only from a
    /// View), so the setter sends `objectWillChange` explicitly — without it,
    /// views switching on `llmProvider` (the model picker in Settings) would
    /// not re-render when the provider changes.
    var llmProvider: LLMProvider {
        get { LLMProvider(rawValue: llmProviderRaw) ?? .anthropic }
        set {
            objectWillChange.send()
            llmProviderRaw = newValue.rawValue
        }
    }

    private var cancellables: Set<AnyCancellable> = []

    init(
        store: RecordingStore? = nil,
        makeSummarizer: ((SummarizerConfig) throws -> any Summarizing)? = nil
    ) {
        self.store = store ?? RecordingStore()
        self.makeSummarizer = makeSummarizer ?? { config in
            try SummarizationFactory.make(config)
        }
        // Republish nested ObservableObject changes so views observing AppState
        // re-render when the recorder/transcriber/store update.
        self.store.objectWillChange
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

        if !TestEnvironment.isRunningTests {
            // Request microphone permission once at launch so the OS dialog
            // appears at a predictable moment — never mid-recording.
            Task { [weak self] in
                await self?.recorder.requestMicrophonePermissionIfNeeded()
            }

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
    }

    func toggleRecording() {
        if recorder.isRecording {
            stopActiveRecordingAndProcess()
        } else {
            requestNewRecording()
        }
    }

    var selectedRecording: Recording? {
        guard let id = selectedRecordingID else { return nil }
        return store.recordings.first { $0.id == id }
    }

    var activeRecording: Recording? {
        guard let id = activeRecordingID else { return nil }
        return store.recordings.first { $0.id == id }
    }

    func requestNewRecording() {
        guard !recorder.isRecording else { return }
        pendingPrefill = nil
        performNewRecordingRequest()
    }

    /// Begin a new recording pre-filled with metadata from a calendar event.
    /// Pass `attendees` only when the user has opted into calendar-based attendee prefill.
    func requestNewRecording(prefilledTitle: String?, prefilledAttendees: [Attendee] = []) {
        guard !recorder.isRecording else { return }
        pendingPrefill = PendingRecordingPrefill(title: prefilledTitle, attendees: prefilledAttendees)
        performNewRecordingRequest()
    }

    private func performNewRecordingRequest() {
        do {
            _ = try startNewRecording()
        } catch {
            NSLog("Failed to start recording: \(error)")
        }
    }

    func stopActiveRecordingAndProcess() {
        if let recording = activeRecording {
            stopRecordingAndProcess(recording)
            return
        }
        if recorder.isRecording {
            liveTranscriptTask?.cancel()
            liveTranscriptTask = nil
            recorder.onChunk = nil
            _ = recorder.stop()
        }
        activeRecordingID = nil
    }

    func clearActiveRecordingIfMatches(_ id: Recording.ID) {
        if activeRecordingID == id {
            activeRecordingID = nil
        }
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
        recorder.onChunk = { [weak self] chunkURL in
            self?.handleChunk(chunkURL)
        }
        recorder.preferredInputDeviceUID = audioInputDeviceUID
        recorder.systemAudioEnabled = systemAudioCaptureEnabled
        try recorder.start(writingTo: url)

        let prefill = pendingPrefill
        pendingPrefill = nil

        let title = prefill?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedTitle = (title?.isEmpty == false) ? title! : Self.suggestedTitle(for: Date())

        var recording = Recording(
            title: resolvedTitle,
            audioFilename: url.lastPathComponent,
            status: .recording,
            attendees: prefill?.attendees ?? [],
            hasSystemAudio: recorder.systemAudioActive
        )
        if let calendarTitle = title {
            recording.calendarEventTitle = calendarTitle
        }
        store.upsert(recording)
        activeRecordingID = recording.id
        selectedRecordingID = recording.id
        return recording
    }

    private func handleChunk(_ url: URL) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let text = try await transcriber.transcribe(fileAt: url)
                try? FileManager.default.removeItem(at: url)
                guard !Task.isCancelled else { return }
                let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !cleaned.isEmpty else { return }
                // Chunks are disjoint audio segments now — append, don't replace.
                self.liveTranscript = self.liveTranscript.isEmpty
                    ? cleaned
                    : self.liveTranscript + " " + cleaned
            } catch {
                NSLog("Live chunk transcription failed: \(error)")
                try? FileManager.default.removeItem(at: url)
            }
        }
        liveTranscriptTask = task
    }

    func stopRecordingAndProcess(_ recording: Recording) {
        liveTranscriptTask?.cancel()
        liveTranscriptTask = nil
        recorder.onChunk = nil
        let stoppedURL = recorder.stop()
        activeRecordingID = nil
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

    /// Permanently deletes an attendee everywhere: removes them from every
    /// recording's attendee list and from the global recents pool so the name
    /// no longer appears in any picker.
    func forgetAttendeeEverywhere(_ name: String) {
        let key = name.lowercased()
        for rec in store.recordings {
            let filtered = rec.attendees.filter { $0.name.lowercased() != key }
            guard filtered.count != rec.attendees.count else { continue }
            var updated = rec
            updated.attendees = filtered
            store.upsert(updated)
        }
        forgetRecentAttendee(name)
    }

    /// Removes a name from the global recents pool permanently.
    func forgetRecentAttendee(_ name: String) {
        let key = name.lowercased()
        let filtered = recentAttendees.filter { $0.lowercased() != key }
        guard filtered.count != recentAttendees.count else { return }
        recentAttendees = filtered
        UserDefaults.standard.set(filtered, forKey: Self.recentAttendeesKey)
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
        updated.lastError = nil
        updated.status = .summarizing
        store.upsert(updated)
        runPipeline(for: updated.id, forceSummarize: true)
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

    private func runPipeline(for id: Recording.ID, forceSummarize: Bool = false) {
        Task { [weak self] in
            await self?.executePipeline(id: id, forceSummarize: forceSummarize)
        }
    }

    /// Re-fetches the latest stored copy of the recording, applies `mutate` to it,
    /// and upserts the result. Because AppState is @MainActor and there is no
    /// suspension point inside, concurrent UI edits can never be clobbered by the
    /// pipeline's long-running steps. Returns the updated value, or nil if the
    /// recording was deleted mid-pipeline.
    @discardableResult
    private func applyPipelineUpdate(
        id: Recording.ID,
        _ mutate: (inout Recording) -> Void
    ) -> Recording? {
        guard var latest = store.recordings.first(where: { $0.id == id }) else { return nil }
        mutate(&latest)
        store.upsert(latest)
        return latest
    }

    /// The pipeline never holds a `Recording` across an `await` and then upserts it —
    /// always go through `applyPipelineUpdate`.
    func executePipeline(id: Recording.ID, forceSummarize: Bool = false) async {
        // Fresh fetch for the initial emptiness check.
        guard let initial = store.recordings.first(where: { $0.id == id }) else { return }

        // Transcribe + diarize (in parallel when both are needed)
        if initial.transcript.isEmpty {
            do {
                guard let snap = applyPipelineUpdate(id: id, { $0.status = .transcribing }) else { return }
                let audioURL = store.audioURL(for: snap)
                let runDiarization = diarizationEnabled

                // Dual-track: attribute tokens to channels (You vs Them).
                // Envelope load streams the file; run it off the main actor.
                var envelopes: ChannelEnvelopes? = nil
                if snap.hasSystemAudio {
                    envelopes = try? await Task.detached {
                        try ChannelEnvelopes.load(from: audioURL)
                    }.value
                    if envelopes?.isStereo != true { envelopes = nil } // mono despite flag → normal path
                }

                if let envelopes {
                    async let asrTask = transcriber.transcribeWithTimings(fileAt: audioURL)
                    // Diarize only the system channel so remote speakers cluster
                    // cleanly and the user's voice never lands in the clusters.
                    var systemSegments: [TimedSpeakerSegment]? = nil
                    // Both awaits below must stay `try?`: a throw between the
                    // `async let asrTask` and `try await asrTask` would skip the
                    // ASR await path this branch depends on.
                    if runDiarization,
                       let systemURL = try? await Task.detached(operation: {
                           try ChannelEnvelopes.writeSystemChannel(from: audioURL)
                       }).value {
                        // -1 (auto): the attendee-count hint includes the user,
                        // who is excluded from the system channel by design.
                        systemSegments = try? await diarizer.diarize(fileAt: systemURL, numSpeakers: -1)
                        try? FileManager.default.removeItem(at: systemURL)
                    }
                    let asrResult = try await asrTask
                    let segments = systemSegments

                    let updated = applyPipelineUpdate(id: id) {
                        $0.transcript = asrResult.text
                        if let timings = asrResult.tokenTimings, !timings.isEmpty {
                            $0.speakerTurns = Self.attributeTokensToChannels(
                                tokens: timings,
                                envelopes: envelopes,
                                systemSegments: segments
                            )
                        }
                    }
                    if updated == nil { return }
                } else if runDiarization {
                    // Speaker count hint: number of currently-checked attendees, if any.
                    // Use the snap from before the await so the hint is consistent.
                    let hintedSpeakerCount = snap.attendees.filter { $0.selected }.count
                    async let asrTask = transcriber.transcribeWithTimings(fileAt: audioURL)
                    async let diarizeTask: [TimedSpeakerSegment]? = (try? await diarizer.diarize(
                        fileAt: audioURL,
                        numSpeakers: hintedSpeakerCount > 1 ? hintedSpeakerCount : -1
                    ))
                    let asrResult = try await asrTask
                    let segments = await diarizeTask

                    let updated = applyPipelineUpdate(id: id) {
                        $0.transcript = asrResult.text
                        if let segments, let timings = asrResult.tokenTimings, !timings.isEmpty {
                            $0.speakerTurns = Self.alignTokensToSpeakers(
                                tokens: timings,
                                segments: segments
                            )
                        }
                    }
                    if updated == nil { return }
                } else {
                    let transcript = try await transcriber.transcribe(fileAt: audioURL)
                    let updated = applyPipelineUpdate(id: id) { $0.transcript = transcript }
                    if updated == nil { return }
                }
            } catch {
                applyPipelineUpdate(id: id) {
                    $0.status = .failed
                    $0.lastError = "Transcription failed: \(error.localizedDescription)"
                }
                return
            }
        }

        // Fresh fetch after transcription completes (catches UI edits made during transcription).
        guard let current = store.recordings.first(where: { $0.id == id }) else { return }

        // Summarize
        if forceSummarize || current.summaryMarkdown.isEmpty {
            do {
                guard applyPipelineUpdate(id: id, { $0.status = .summarizing }) != nil else { return }
                let summarizer = try makeSummarizer(SummarizerConfig(
                    provider: llmProvider,
                    anthropicModel: anthropicModel,
                    openRouterModel: openRouterModel
                ))
                // Don't pass the placeholder "Recording — date" title as a suggestion —
                // models tend to reuse it verbatim instead of inventing a real title.
                let selectedAttendees = current.attendees
                    .filter { $0.selected }
                    .map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }

                // When we have speaker turns, feed the model the speaker-labeled version.
                // Otherwise, fall back to the raw transcript.
                let transcriptForModel: String = current.speakerTurns.isEmpty
                    ? current.transcript
                    : Self.formatSpeakerTurns(current.speakerTurns)

                let summaryOnly = try await summarizer.summarize(
                    transcript: transcriptForModel,
                    liveNotes: current.liveNotes,
                    attendees: selectedAttendees,
                    speakerLabeled: !current.speakerTurns.isEmpty,
                    suggestedTitle: nil,
                    systemPromptOverride: anthropicSystemPrompt,
                    userPromptTemplateOverride: anthropicUserPromptTemplate
                )
                // Build combined using `current` (captured before the summarize await).
                // Notes/speakerTurns/transcript don't change during summarize in any
                // supported UI flow, so using the pre-await snapshot is acceptable.
                let trimmedNotes = current.liveNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                let notesSection = trimmedNotes.isEmpty ? "" : """

                ## 📝 Notes taken during meeting

                \(trimmedNotes)

                """
                let transcriptSection = current.speakerTurns.isEmpty
                    ? current.transcript
                    : Self.formatSpeakerTurns(current.speakerTurns)
                let combined = """
                \(summaryOnly.trimmingCharacters(in: .whitespacesAndNewlines))
                \(notesSection)
                ---

                ## Raw transcript

                \(transcriptSection)
                """
                applyPipelineUpdate(id: id) {
                    $0.summaryMarkdown = combined
                    if $0.calendarEventTitle == nil,
                       let extracted = Self.extractTitle(from: summaryOnly), !extracted.isEmpty {
                        $0.title = extracted
                    }
                    $0.status = .ready
                }
            } catch {
                applyPipelineUpdate(id: id) {
                    $0.status = .failed
                    $0.lastError = "Summarization failed: \(error.localizedDescription)"
                }
                return
            }
        } else {
            applyPipelineUpdate(id: id) { $0.status = .ready }
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

    /// Shared turn-builder: walks tokens, asks `labelFor` for each token's speaker
    /// label, joins consecutive same-label tokens into runs, and reassembles
    /// SentencePiece pieces (▁ = word boundary) into text.
    private static func buildTurns(
        tokens: [TokenTiming],
        labelFor: (TokenTiming) -> String
    ) -> [SpeakerTurn] {
        var turns: [SpeakerTurn] = []
        var currentLabel: String? = nil
        var currentStart: Double = 0
        var currentEnd: Double = 0
        var currentPieces: [String] = []

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
            let label = labelFor(token)
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
        var segIdx = 0

        return buildTurns(tokens: tokens) { token in
            let mid = (token.startTime + token.endTime) / 2
            // Advance segment cursor past any segments fully behind us.
            while segIdx + 1 < sortedSegments.count,
                  Double(sortedSegments[segIdx + 1].startTimeSeconds) <= mid {
                segIdx += 1
            }
            return labelFor(sortedSegments[segIdx].speakerId)
        }
    }

    /// Dual-track attribution: mic-energy tokens are "You"; system-energy tokens
    /// are "Them", or — when the system channel was diarized — "Speaker N" with
    /// stable first-appearance numbering.
    static func attributeTokensToChannels(
        tokens: [TokenTiming],
        envelopes: ChannelEnvelopes,
        systemSegments: [TimedSpeakerSegment]?
    ) -> [SpeakerTurn] {
        guard !tokens.isEmpty else { return [] }

        var labelMap: [String: String] = [:]
        var nextSpeakerNumber = 1
        let sortedSegments = (systemSegments ?? []).sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var segIdx = 0

        return buildTurns(tokens: tokens) { token in
            switch envelopes.source(start: token.startTime, end: token.endTime) {
            case .mic:
                return "You"
            case .system:
                guard !sortedSegments.isEmpty else { return "Them" }
                let mid = (token.startTime + token.endTime) / 2
                while segIdx + 1 < sortedSegments.count,
                      Double(sortedSegments[segIdx + 1].startTimeSeconds) <= mid {
                    segIdx += 1
                }
                let rawId = sortedSegments[segIdx].speakerId
                if let existing = labelMap[rawId] { return existing }
                let label = "Speaker \(nextSpeakerNumber)"
                nextSpeakerNumber += 1
                labelMap[rawId] = label
                return label
            }
        }
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

    /// Append live-chunk turns to the accumulated list. A speaker talking across
    /// a chunk boundary produces a same-label turn pair; merge those into one
    /// block instead of repeating the label.
    static func appendingTurns(_ new: [SpeakerTurn], to existing: [SpeakerTurn]) -> [SpeakerTurn] {
        guard var last = existing.last, let first = new.first,
              last.speakerLabel == first.speakerLabel else {
            return existing + new
        }
        last.text += " " + first.text
        last.endSec = first.endSec
        return existing.dropLast() + [last] + new.dropFirst()
    }
}
