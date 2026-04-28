import Foundation
import AVFAudio
import FluidAudio

@MainActor
final class TranscriptionService: ObservableObject {
    enum ModelState: Equatable {
        case notLoaded
        case checking
        case downloading(progress: Double, message: String)
        case compiling(message: String)
        case ready
        case failed(String)

        var isReady: Bool {
            if case .ready = self { return true }
            return false
        }

        /// True when work is happening that the user should be told about with a sheet.
        var isHeavy: Bool {
            switch self {
            case .downloading, .compiling: return true
            default: return false
            }
        }
    }

    @Published private(set) var modelState: ModelState = .notLoaded

    /// True when Parakeet model files are present on disk before we start loading.
    /// Used to decide whether to surface a noisy first-run sheet or load silently.
    @Published private(set) var hasLocalModels: Bool = false

    private var asrManager: AsrManager?
    private var loadTask: Task<Void, Error>?

    init() {
        // Cheap, synchronous check on init so the UI knows whether to brace for a download.
        let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
        self.hasLocalModels = AsrModels.modelsExist(at: cacheDir, version: .v3)
    }

    func ensureLoaded() async throws {
        if case .ready = modelState { return }
        if let loadTask {
            try await loadTask.value
            return
        }
        let task = Task<Void, Error> { [weak self] in
            guard let self else { return }
            try await self.loadModelsImpl()
        }
        loadTask = task
        defer { loadTask = nil }
        try await task.value
    }

    private func loadModelsImpl() async throws {
        let cacheDir = AsrModels.defaultCacheDirectory(for: .v3)
        let alreadyHave = AsrModels.modelsExist(at: cacheDir, version: .v3)
        hasLocalModels = alreadyHave

        modelState = alreadyHave
            ? .compiling(message: "Loading speech model into the Neural Engine…")
            : .checking

        do {
            let models = try await AsrModels.downloadAndLoad(
                version: .v3,
                progressHandler: { [weak self] progress in
                    let fraction = progress.fractionCompleted
                    let phaseMessage = Self.message(for: progress.phase)
                    let isCompile: Bool
                    if case .compiling = progress.phase { isCompile = true } else { isCompile = false }
                    Task { @MainActor in
                        guard let self else { return }
                        if isCompile {
                            self.modelState = .compiling(message: phaseMessage)
                        } else {
                            self.modelState = .downloading(progress: fraction, message: phaseMessage)
                        }
                    }
                }
            )
            modelState = .compiling(message: "Loading speech model into the Neural Engine…")
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            self.asrManager = manager
            self.hasLocalModels = true
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
            throw error
        }
    }

    func transcribe(fileAt url: URL) async throws -> String {
        try await ensureLoaded()
        guard let asrManager else {
            throw NSError(domain: "TranscriptionService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "ASR manager not ready"])
        }
        return try await Self.runTranscription(manager: asrManager, fileURL: url)
    }

    /// Returns the full ASRResult including token timings, for downstream alignment
    /// against speaker diarization. Used in the final pipeline (not the live-chunk path).
    func transcribeWithTimings(fileAt url: URL) async throws -> ASRResult {
        try await ensureLoaded()
        guard let asrManager else {
            throw NSError(domain: "TranscriptionService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "ASR manager not ready"])
        }
        var decoderState = TdtDecoderState.make()
        return try await asrManager.transcribe(url, decoderState: &decoderState)
    }

    private static func runTranscription(manager: AsrManager, fileURL: URL) async throws -> String {
        var decoderState = TdtDecoderState.make()
        let result = try await manager.transcribe(fileURL, decoderState: &decoderState)
        return result.text
    }

    nonisolated private static func message(for phase: DownloadUtils.DownloadPhase) -> String {
        switch phase {
        case .listing:
            return "Looking up speech model files…"
        case .downloading(let done, let total):
            if total > 0 {
                return "Downloading speech model — \(done) of \(total) files"
            }
            return "Downloading speech model…"
        case .compiling(let modelName):
            return "Optimizing \(modelName) for the Neural Engine…"
        }
    }
}
