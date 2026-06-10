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
}
