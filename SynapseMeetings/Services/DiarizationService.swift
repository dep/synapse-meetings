import Foundation
import AVFAudio
import FluidAudio

@MainActor
final class DiarizationService: ObservableObject {
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
    }

    @Published private(set) var modelState: ModelState = .notLoaded

    private var manager: DiarizerManager?
    private var loadTask: Task<Void, Error>?

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
        modelState = .checking
        do {
            let models = try await DiarizerModels.download(progressHandler: { [weak self] progress in
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
            })
            modelState = .compiling(message: "Loading speaker model into the Neural Engine…")
            let m = DiarizerManager(config: .default)
            m.initialize(models: consume models)
            self.manager = m
            modelState = .ready
        } catch {
            modelState = .failed(error.localizedDescription)
            throw error
        }
    }

    /// Diarize the WAV file at `url`. If `numSpeakers > 0`, that count is enforced;
    /// otherwise speakers are auto-detected by clustering.
    func diarize(fileAt url: URL, numSpeakers: Int = -1) async throws -> [TimedSpeakerSegment] {
        try await ensureLoaded()
        let m = try await managerFor(numSpeakers: numSpeakers)
        let samples = try Self.loadMonoFloat32(at: url)
        let result = try await m.performCompleteDiarization(
            samples,
            sampleRate: 16_000
        )
        return result.segments
    }

    /// Returns the cached default manager for auto-detect, or a fresh manager
    /// with `numClusters = numSpeakers` for known counts. The second case still
    /// reads pre-cached models from disk — the heavy download already happened
    /// in `ensureLoaded`.
    private func managerFor(numSpeakers: Int) async throws -> DiarizerManager {
        if numSpeakers <= 0, let manager { return manager }
        guard let manager else {
            throw NSError(domain: "DiarizationService", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Diarizer not ready"])
        }
        if numSpeakers <= 0 { return manager }

        // Build a fresh manager with the speaker-count hint applied.
        var cfg = DiarizerConfig.default
        cfg.numClusters = numSpeakers
        let m = DiarizerManager(config: cfg)
        // Re-load the (already-cached on disk) models. This is fast — no network.
        let models = try await DiarizerModels.download()
        m.initialize(models: consume models)
        return m
    }

    /// Loads `url` as a mono Float32 array at 16kHz. The recorder already writes
    /// in this format, so this is mostly a typed re-read.
    nonisolated private static func loadMonoFloat32(at url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat

        // Build the target format the diarizer expects.
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "DiarizationService", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not build target audio format"])
        }

        // Fast path: file already matches.
        if inputFormat.sampleRate == targetFormat.sampleRate && inputFormat.channelCount == 1 {
            let frameCount = AVAudioFrameCount(file.length)
            guard frameCount > 0,
                  let buffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: frameCount) else {
                return []
            }
            try file.read(into: buffer)
            return Self.copy(buffer: buffer)
        }

        // Otherwise, resample/downmix.
        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw NSError(domain: "DiarizationService", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not build audio converter"])
        }

        let inputFrameCount = AVAudioFrameCount(file.length)
        guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: inputFrameCount) else {
            return []
        }
        try file.read(into: inputBuffer)

        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 1024)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputCapacity) else {
            return []
        }

        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .endOfStream
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return inputBuffer
        }

        if status == .error || convError != nil {
            throw convError ?? NSError(domain: "DiarizationService", code: -4)
        }

        return Self.copy(buffer: outputBuffer)
    }

    nonisolated private static func copy(buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData?[0] else { return [] }
        let count = Int(buffer.frameLength)
        return Array(UnsafeBufferPointer(start: channelData, count: count))
    }

    nonisolated private static func message(for phase: DownloadUtils.DownloadPhase) -> String {
        switch phase {
        case .listing:
            return "Looking up speaker model files…"
        case .downloading(let done, let total):
            if total > 0 {
                return "Downloading speaker model — \(done) of \(total) files"
            }
            return "Downloading speaker model…"
        case .compiling(let modelName):
            return "Optimizing \(modelName) for the Neural Engine…"
        }
    }
}
