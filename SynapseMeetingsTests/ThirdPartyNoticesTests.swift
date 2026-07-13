import XCTest
@testable import Synapse_Meetings

final class ThirdPartyNoticesTests: XCTestCase {
    func testNoticesFileIsBundledWithRequiredLicenseTexts() throws {
        let url = try XCTUnwrap(
            Bundle(for: AppState.self).url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md"),
            "THIRD-PARTY-NOTICES.md must ship inside the app bundle"
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("Sparkle"))
        XCTAssertTrue(text.contains("Apache License"))
        XCTAssertTrue(text.contains("FluidAudio"))
        XCTAssertTrue(text.contains("CC BY 4.0"))
        XCTAssertTrue(text.contains("parakeet-tdt-0.6b-v3"))
        XCTAssertTrue(text.contains("speaker-diarization-community-1"))
    }
}
