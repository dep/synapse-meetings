import XCTest
@testable import Synapse_Meetings

@MainActor
final class PipelineExecutionTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - Helpers

    private struct StubSummarizer: Summarizing {
        var result: Result<String, Error>
        func summarize(
            transcript: String,
            liveNotes: String,
            attendees: [String],
            speakerLabeled: Bool,
            suggestedTitle: String?,
            systemPromptOverride: String?,
            userPromptTemplateOverride: String?
        ) async throws -> String {
            try result.get()
        }
    }

    private struct TestError: Error {}

    private func makeApp(summary: Result<String, Error>) -> AppState {
        AppState(
            store: RecordingStore(baseDirectory: tempDir),
            makeSummarizer: { _ in StubSummarizer(result: summary) }
        )
    }

    // MARK: - Tests

    func testSummarizeSuccess_setsSummaryAndReady() async throws {
        let app = makeApp(summary: .success("# New Title\n\nBody"))
        var rec = Recording(audioFilename: "test.wav")
        rec.transcript = "Some transcript text"
        rec.status = .summarizing
        app.store.upsert(rec)

        await app.executePipeline(id: rec.id)

        let result = app.store.recordings.first(where: { $0.id == rec.id })
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .ready)
        XCTAssertTrue(result?.summaryMarkdown.contains("# New Title") == true)
        XCTAssertTrue(result?.summaryMarkdown.contains("## Raw transcript") == true)
        XCTAssertEqual(result?.title, "New Title")
    }

    func testSummarizeFailure_setsFailedAndKeepsError() async throws {
        let app = makeApp(summary: .failure(TestError()))
        var rec = Recording(audioFilename: "test.wav")
        rec.transcript = "Some transcript text"
        rec.status = .summarizing
        app.store.upsert(rec)

        await app.executePipeline(id: rec.id)

        let result = app.store.recordings.first(where: { $0.id == rec.id })
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .failed)
        XCTAssertTrue(result?.lastError?.hasPrefix("Summarization failed:") == true)
    }

    /// Plan-001 regression: a forced re-summarize that fails must preserve the old summary.
    func testForcedResummarizeFailure_preservesOldSummary() async throws {
        let app = makeApp(summary: .failure(TestError()))
        var rec = Recording(audioFilename: "test.wav")
        rec.transcript = "Some transcript text"
        rec.summaryMarkdown = "# Old\n\nPrecious edits"
        rec.status = .summarizing
        app.store.upsert(rec)

        await app.executePipeline(id: rec.id, forceSummarize: true)

        let result = app.store.recordings.first(where: { $0.id == rec.id })
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.summaryMarkdown, "# Old\n\nPrecious edits")
        XCTAssertEqual(result?.status, .failed)
    }

    func testNonEmptySummaryWithoutForce_skipsSummarizerAndLandsReady() async throws {
        final class Flag { var called = false }
        let flag = Flag()
        let app = AppState(
            store: RecordingStore(baseDirectory: tempDir),
            makeSummarizer: { _ in
                struct ThrowingStub: Summarizing {
                    let flag: Flag
                    func summarize(
                        transcript: String,
                        liveNotes: String,
                        attendees: [String],
                        speakerLabeled: Bool,
                        suggestedTitle: String?,
                        systemPromptOverride: String?,
                        userPromptTemplateOverride: String?
                    ) async throws -> String {
                        flag.called = true
                        throw TestError()
                    }
                }
                return ThrowingStub(flag: flag)
            }
        )

        var rec = Recording(audioFilename: "test.wav")
        rec.transcript = "Some transcript text"
        rec.summaryMarkdown = "# Existing summary\n\nContent"
        rec.status = .ready
        app.store.upsert(rec)

        await app.executePipeline(id: rec.id)

        let result = app.store.recordings.first(where: { $0.id == rec.id })
        XCTAssertEqual(result?.status, .ready)
        XCTAssertFalse(flag.called)
    }

    func testCalendarTitlePreserved() async throws {
        let app = makeApp(summary: .success("# AI Title\n\nBody"))
        var rec = Recording(audioFilename: "test.wav")
        rec.transcript = "Some transcript text"
        rec.calendarEventTitle = "Standup"
        rec.status = .summarizing
        app.store.upsert(rec)

        await app.executePipeline(id: rec.id)

        let result = app.store.recordings.first(where: { $0.id == rec.id })
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .ready)
        XCTAssertNotEqual(result?.title, "AI Title")
    }

    // MARK: - Plan-006 lost-update regression tests

    private final class GatedSummarizer: Summarizing, @unchecked Sendable {
        private let (stream, continuation) = AsyncStream<Void>.makeStream()
        func summarize(
            transcript: String,
            liveNotes: String,
            attendees: [String],
            speakerLabeled: Bool,
            suggestedTitle: String?,
            systemPromptOverride: String?,
            userPromptTemplateOverride: String?
        ) async throws -> String {
            for await _ in stream { break }   // park until the test releases us
            return "# Done\n\nSummary"
        }
        func release() { continuation.yield(); continuation.finish() }
    }

    /// Verifies that a UI edit made while the pipeline is awaiting the summarizer
    /// is NOT clobbered by the pipeline's final write. With the old whole-struct
    /// upsert, the stale snapshot (no attendees) would silently overwrite Sarah.
    func testEditDuringSummarize_isNotClobbered() async throws {
        let summarizer = GatedSummarizer()
        let app = AppState(
            store: RecordingStore(baseDirectory: tempDir),
            makeSummarizer: { _ in summarizer }
        )
        var rec = Recording(audioFilename: "test.wav")
        rec.transcript = "Some transcript text"
        rec.summaryMarkdown = ""
        rec.status = .summarizing
        app.store.upsert(rec)

        // Start the pipeline — it will park inside GatedSummarizer.
        let pipelineTask = Task { await app.executePipeline(id: rec.id) }

        // Yield enough times to let the pipeline suspend inside the summarizer.
        for _ in 0..<20 { await Task.yield() }

        // Simulate a UI edit that happens while the pipeline is awaiting.
        app.updateAttendees(for: rec.id, attendees: [Attendee(name: "Sarah")])

        // Release the summarizer and let the pipeline finish.
        summarizer.release()
        await pipelineTask.value

        let result = app.store.recordings.first(where: { $0.id == rec.id })
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.status, .ready)
        XCTAssertTrue(result?.summaryMarkdown.contains("# Done") == true,
                      "Summary should contain the returned content")
        XCTAssertEqual(result?.attendees.first?.name, "Sarah",
                       "Attendee edit must not be clobbered by the pipeline write-back")
    }

    /// Verifies that a recording deleted mid-pipeline stays deleted and is NOT
    /// resurrected by the pipeline's final write.
    func testDeletedDuringPipeline_staysDeleted() async throws {
        let summarizer = GatedSummarizer()
        let app = AppState(
            store: RecordingStore(baseDirectory: tempDir),
            makeSummarizer: { _ in summarizer }
        )
        var rec = Recording(audioFilename: "test.wav")
        rec.transcript = "Some transcript text"
        rec.summaryMarkdown = ""
        rec.status = .summarizing
        app.store.upsert(rec)

        // Start the pipeline — it will park inside GatedSummarizer.
        let pipelineTask = Task { await app.executePipeline(id: rec.id) }

        // Yield enough times to let the pipeline suspend inside the summarizer.
        for _ in 0..<20 { await Task.yield() }

        // Delete the recording while the pipeline is parked.
        if let toDelete = app.store.recordings.first(where: { $0.id == rec.id }) {
            app.store.delete(toDelete)
        }

        // Release and await — the pipeline should exit without resurrecting the record.
        summarizer.release()
        await pipelineTask.value

        XCTAssertNil(
            app.store.recordings.first(where: { $0.id == rec.id }),
            "Deleted recording must not be resurrected by the pipeline"
        )
    }

    private final class CapturingSummarizer: Summarizing, @unchecked Sendable {
        private(set) var receivedTranscript: String = ""
        private(set) var receivedSpeakerLabeled: Bool = false
        func summarize(
            transcript: String,
            liveNotes: String,
            attendees: [String],
            speakerLabeled: Bool,
            suggestedTitle: String?,
            systemPromptOverride: String?,
            userPromptTemplateOverride: String?
        ) async throws -> String {
            receivedTranscript = transcript
            receivedSpeakerLabeled = speakerLabeled
            return "# Done\n\nSummary"
        }
    }

    /// Dual-track recordings feed the summarizer a You/Them-labeled transcript
    /// through the existing speakerTurns path.
    func testDualTrackSpeakerTurns_flowToSummarizer() async throws {
        let summarizer = CapturingSummarizer()
        let app = AppState(
            store: RecordingStore(baseDirectory: tempDir),
            makeSummarizer: { _ in summarizer }
        )
        var rec = Recording(audioFilename: "test.wav", hasSystemAudio: true)
        rec.transcript = "Hi there Hello back"
        rec.speakerTurns = [
            SpeakerTurn(speakerLabel: "You", startSec: 0, endSec: 1, text: "Hi there"),
            SpeakerTurn(speakerLabel: "Them", startSec: 1, endSec: 2, text: "Hello back")
        ]
        rec.status = .summarizing
        app.store.upsert(rec)

        await app.executePipeline(id: rec.id)

        XCTAssertTrue(summarizer.receivedSpeakerLabeled)
        XCTAssertEqual(summarizer.receivedTranscript, "You: Hi there\n\nThem: Hello back")
        let result = app.store.recordings.first(where: { $0.id == rec.id })
        XCTAssertEqual(result?.status, .ready)
        XCTAssertTrue(result?.summaryMarkdown.contains("You: Hi there") == true,
                      "Raw transcript section must carry the You/Them labels")
    }
}
