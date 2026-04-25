import Foundation
import Combine

@MainActor
final class RecordingStore: ObservableObject {
    /// Folder name used inside `~/Library/Application Support/`. Migrations rely on this constant.
    static let appSupportFolderName = "Synapse Meetings"

    /// Resolves the app's base directory under Application Support without instantiating the store.
    static func baseDirectoryURL() -> URL {
        let appSupport = try! FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupport.appendingPathComponent(appSupportFolderName, isDirectory: true)
    }

    @Published private(set) var recordings: [Recording] = []

    private let fileManager = FileManager.default
    private let baseDirectory: URL
    private let metadataDirectory: URL
    private let audioDirectory: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        baseDirectory = Self.baseDirectoryURL()
        metadataDirectory = baseDirectory.appendingPathComponent("recordings", isDirectory: true)
        audioDirectory = baseDirectory.appendingPathComponent("audio", isDirectory: true)
        try? fileManager.createDirectory(at: metadataDirectory, withIntermediateDirectories: true)
        try? fileManager.createDirectory(at: audioDirectory, withIntermediateDirectories: true)
        loadAll()
    }

    func audioURL(for recording: Recording) -> URL {
        audioDirectory.appendingPathComponent(recording.audioFilename)
    }

    func newAudioURL(suggestedExtension ext: String = "wav") -> URL {
        let name = "\(UUID().uuidString).\(ext)"
        return audioDirectory.appendingPathComponent(name)
    }

    func loadAll() {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: metadataDirectory,
            includingPropertiesForKeys: nil
        ) else { return }
        let loaded: [Recording] = urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Recording.self, from: data)
            }
            .sorted { $0.createdAt > $1.createdAt }
        self.recordings = loaded
    }

    func upsert(_ recording: Recording) {
        if let idx = recordings.firstIndex(where: { $0.id == recording.id }) {
            recordings[idx] = recording
        } else {
            recordings.insert(recording, at: 0)
        }
        persist(recording)
    }

    func delete(_ recording: Recording) {
        recordings.removeAll { $0.id == recording.id }
        let metadataURL = metadataDirectory.appendingPathComponent("\(recording.id.uuidString).json")
        try? fileManager.removeItem(at: metadataURL)
        let audioFileURL = audioURL(for: recording)
        try? fileManager.removeItem(at: audioFileURL)
    }

    private func persist(_ recording: Recording) {
        let url = metadataDirectory.appendingPathComponent("\(recording.id.uuidString).json")
        do {
            let data = try encoder.encode(recording)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Failed to persist recording \(recording.id): \(error)")
        }
    }
}
