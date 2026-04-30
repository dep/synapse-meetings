import XCTest
@testable import Synapse_Meetings

final class AnthropicPromptTests: XCTestCase {

    // MARK: - renderUserPrompt placeholder substitution

    private func render(
        transcript: String = "Test transcript.",
        liveNotes: String = "",
        attendees: [String] = [],
        speakerLabeled: Bool = false
    ) -> String {
        AnthropicService.testRenderUserPrompt(
            template: AnthropicService.defaultUserPromptTemplate,
            transcript: transcript,
            liveNotes: liveNotes,
            attendees: attendees,
            speakerLabeled: speakerLabeled
        )
    }

    func testRenderUserPrompt_transcriptSubstituted() {
        let result = render(transcript: "Alice said hello.")
        XCTAssertTrue(result.contains("Alice said hello."))
        XCTAssertFalse(result.contains("{{TRANSCRIPT}}"))
    }

    func testRenderUserPrompt_noLeftoverPlaceholders() {
        let result = render(transcript: "foo", liveNotes: "bar", attendees: ["Alice"], speakerLabeled: true)
        XCTAssertFalse(result.contains("{{"))
        XCTAssertFalse(result.contains("}}"))
    }

    func testRenderUserPrompt_emptyAttendeesBlock() {
        let result = render(attendees: [])
        XCTAssertFalse(result.contains("[["))
    }

    func testRenderUserPrompt_attendeesWrappedInObsidianLinks() {
        let result = render(attendees: ["Alice", "Bob"])
        XCTAssertTrue(result.contains("[[Alice]]"))
        XCTAssertTrue(result.contains("[[Bob]]"))
    }

    func testRenderUserPrompt_attendeesBulletList() {
        let result = render(attendees: ["Alice", "Bob"])
        XCTAssertTrue(result.contains("- [[Alice]]"))
        XCTAssertTrue(result.contains("- [[Bob]]"))
    }

    func testRenderUserPrompt_emptyLiveNotes_noNotesBlock() {
        let result = render(liveNotes: "")
        XCTAssertFalse(result.contains("high-signal"))
    }

    func testRenderUserPrompt_emptyLiveNotes_whitespaceOnly_noNotesBlock() {
        let result = render(liveNotes: "   \n  ")
        XCTAssertFalse(result.contains("high-signal"))
    }

    func testRenderUserPrompt_liveNotesIncluded() {
        let result = render(liveNotes: "Discussed pricing model.")
        XCTAssertTrue(result.contains("Discussed pricing model."))
        XCTAssertTrue(result.contains("high-signal"))
    }

    func testRenderUserPrompt_speakerBlock_absent_whenNotLabeled() {
        let result = render(speakerLabeled: false)
        XCTAssertFalse(result.contains("diarized"))
    }

    func testRenderUserPrompt_speakerBlock_present_whenLabeled() {
        let result = render(speakerLabeled: true)
        XCTAssertTrue(result.contains("diarized"))
        XCTAssertTrue(result.contains("Speaker 1"))
    }

    // MARK: - defaultSystemPrompt content

    func testDefaultSystemPrompt_requiresH1Title() {
        XCTAssertTrue(AnthropicService.defaultSystemPrompt.contains("H1"))
    }

    func testDefaultSystemPrompt_forbidsGenericTitles() {
        XCTAssertTrue(AnthropicService.defaultSystemPrompt.contains("generic"))
    }
}
