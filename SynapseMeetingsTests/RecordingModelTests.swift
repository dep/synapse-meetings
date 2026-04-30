import XCTest
@testable import Synapse_Meetings

final class RecordingModelTests: XCTestCase {

    // MARK: - Recording.isNote

    func testIsNote_emptyAudioFilename() {
        let note = Recording(audioFilename: "")
        XCTAssertTrue(note.isNote)
    }

    func testIsNote_withAudioFilename() {
        let rec = Recording(audioFilename: "abc.wav")
        XCTAssertFalse(rec.isNote)
    }

    // MARK: - RecordingStatus.displayLabel

    func testDisplayLabels() {
        XCTAssertEqual(RecordingStatus.recording.displayLabel, "Recording…")
        XCTAssertEqual(RecordingStatus.transcribing.displayLabel, "Transcribing…")
        XCTAssertEqual(RecordingStatus.summarizing.displayLabel, "Summarizing…")
        XCTAssertEqual(RecordingStatus.ready.displayLabel, "Ready")
        XCTAssertEqual(RecordingStatus.committed.displayLabel, "Committed")
        XCTAssertEqual(RecordingStatus.failed.displayLabel, "Failed")
    }

    // MARK: - Codable round-trip

    func testRecordingRoundTrip_basicFields() throws {
        let original = Recording(
            title: "Test Meeting",
            audioFilename: "audio.wav",
            transcript: "Hello world",
            liveNotes: "Some notes",
            summaryMarkdown: "# Test Meeting\n\nSummary here.",
            status: .ready,
            attendees: [Attendee(name: "Alice", selected: true), Attendee(name: "Bob", selected: false)]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Recording.self, from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.title, original.title)
        XCTAssertEqual(decoded.audioFilename, original.audioFilename)
        XCTAssertEqual(decoded.transcript, original.transcript)
        XCTAssertEqual(decoded.liveNotes, original.liveNotes)
        XCTAssertEqual(decoded.summaryMarkdown, original.summaryMarkdown)
        XCTAssertEqual(decoded.status, original.status)
        XCTAssertEqual(decoded.attendees.map(\.name), ["Alice", "Bob"])
        XCTAssertEqual(decoded.attendees.map(\.selected), [true, false])
    }

    func testRecordingRoundTrip_calendarEventTitle() throws {
        var original = Recording(audioFilename: "audio.wav")
        original.calendarEventTitle = "Q3 Planning"

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let data = try encoder.encode(original)
        let decoded = try decoder.decode(Recording.self, from: data)

        XCTAssertEqual(decoded.calendarEventTitle, "Q3 Planning")
    }

    func testRecordingDecoding_missingOptionalFieldsDefaultGracefully() throws {
        // Simulate a JSON from an older version that lacks newer optional fields
        let json = """
        {
            "id": "00000000-0000-0000-0000-000000000001",
            "title": "Old Recording",
            "createdAt": "2024-01-01T10:00:00Z",
            "duration": 0,
            "audioFilename": "old.wav",
            "transcript": "",
            "summaryMarkdown": "",
            "status": "ready"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let recording = try decoder.decode(Recording.self, from: Data(json.utf8))

        XCTAssertEqual(recording.title, "Old Recording")
        XCTAssertEqual(recording.liveNotes, "")
        XCTAssertTrue(recording.attendees.isEmpty)
        XCTAssertTrue(recording.speakerTurns.isEmpty)
        XCTAssertNil(recording.calendarEventTitle)
        XCTAssertNil(recording.committedRepo)
    }
}
