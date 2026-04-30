import XCTest
@testable import Synapse_Meetings

@MainActor
final class RecordingStoreTests: XCTestCase {

    private var tempDir: URL!
    private var store: RecordingStore!

    override func setUp() async throws {
        try await super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        store = RecordingStore(baseDirectory: tempDir)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
        try await super.tearDown()
    }

    // MARK: - upsert / insert

    func testUpsert_insert_appearsInRecordings() {
        let rec = Recording(title: "Test", audioFilename: "a.wav")
        store.upsert(rec)
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(store.recordings[0].title, "Test")
    }

    func testUpsert_update_replacesExisting() {
        var rec = Recording(title: "Original", audioFilename: "a.wav")
        store.upsert(rec)
        rec.title = "Updated"
        store.upsert(rec)
        XCTAssertEqual(store.recordings.count, 1)
        XCTAssertEqual(store.recordings[0].title, "Updated")
    }

    func testUpsert_multipleRecordings_sortedByCreatedAtDescending() {
        let older = Recording(title: "Older", createdAt: Date(timeIntervalSince1970: 1000), audioFilename: "a.wav")
        let newer = Recording(title: "Newer", createdAt: Date(timeIntervalSince1970: 2000), audioFilename: "b.wav")
        store.upsert(older)
        store.upsert(newer)
        // loadAll sorts descending; in-memory insert puts new at index 0
        // After a reload the order must be descending
        store.loadAll()
        XCTAssertEqual(store.recordings.first?.title, "Newer")
        XCTAssertEqual(store.recordings.last?.title, "Older")
    }

    // MARK: - delete

    func testDelete_removesFromRecordings() {
        let rec = Recording(title: "Deletable", audioFilename: "del.wav")
        store.upsert(rec)
        store.delete(rec)
        XCTAssertTrue(store.recordings.isEmpty)
    }

    func testDelete_removesMetadataFile() {
        let rec = Recording(title: "Deletable", audioFilename: "del.wav")
        store.upsert(rec)
        let metaURL = tempDir.appendingPathComponent("recordings/\(rec.id.uuidString).json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaURL.path))
        store.delete(rec)
        XCTAssertFalse(FileManager.default.fileExists(atPath: metaURL.path))
    }

    // MARK: - persistence / loadAll round-trip

    func testLoadAll_reloadsPersistedRecordings() {
        let rec = Recording(title: "Persisted", audioFilename: "p.wav", status: .ready)
        store.upsert(rec)

        let freshStore = RecordingStore(baseDirectory: tempDir)
        XCTAssertEqual(freshStore.recordings.count, 1)
        XCTAssertEqual(freshStore.recordings[0].title, "Persisted")
        XCTAssertEqual(freshStore.recordings[0].status, .ready)
    }

    func testLoadAll_ignoresNonJsonFiles() throws {
        let junkURL = tempDir.appendingPathComponent("recordings/not_a_recording.txt")
        try "junk".write(to: junkURL, atomically: true, encoding: .utf8)
        store.loadAll()
        XCTAssertTrue(store.recordings.isEmpty)
    }

    func testLoadAll_silentlySkipsMalformedJson() throws {
        let badURL = tempDir.appendingPathComponent("recordings/\(UUID().uuidString).json")
        try "{ not valid json }".write(to: badURL, atomically: true, encoding: .utf8)
        store.loadAll()
        XCTAssertTrue(store.recordings.isEmpty)
    }

    // MARK: - audioURL

    func testAudioURL_correctlyLocated() {
        let rec = Recording(audioFilename: "meeting.wav")
        let url = store.audioURL(for: rec)
        XCTAssertEqual(url.lastPathComponent, "meeting.wav")
        XCTAssertTrue(url.path.contains("audio"))
    }

    // MARK: - newAudioURL

    func testNewAudioURL_uniqueUUIDs() {
        let url1 = store.newAudioURL()
        let url2 = store.newAudioURL()
        XCTAssertNotEqual(url1, url2)
    }

    func testNewAudioURL_defaultExtensionIsWav() {
        let url = store.newAudioURL()
        XCTAssertEqual(url.pathExtension, "wav")
    }

    func testNewAudioURL_customExtension() {
        let url = store.newAudioURL(suggestedExtension: "m4a")
        XCTAssertEqual(url.pathExtension, "m4a")
    }
}
