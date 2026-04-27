import Foundation
import AVFoundation
import Combine

@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var lastError: String?

    private let engine = AVAudioEngine()
    private var audioFile: AVAudioFile?
    private var converter: AVAudioConverter?
    private var startedAt: Date?
    private var timer: Timer?
    private var outputURL: URL?
    private var targetFormat: AVAudioFormat?

    /// In-memory PCM samples written so far (mono float32). Used to materialize
    /// a properly-finalized WAV snapshot for chunked transcription.
    private var pcmBuffer: [Float] = []
    private let pcmBufferQueue = DispatchQueue(label: "AudioRecorder.pcmBuffer")

    private let targetSampleRate: Double = 16_000
    private let targetChannels: AVAudioChannelCount = 1

    /// Called periodically with a snapshot URL of audio written so far.
    var onChunk: ((URL) -> Void)?
    private var chunkTimer: Timer?
    private let chunkInterval: TimeInterval = 10

    func start(writingTo url: URL) throws {
        guard !isRecording else { return }
        lastError = nil
        outputURL = url

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: targetChannels,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioRecorder", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not build target audio format"])
        }

        // AVAudioFile written in target format (16kHz mono Float32 WAV)
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: targetChannels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        audioFile = try AVAudioFile(forWriting: url, settings: fileSettings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)

        self.targetFormat = targetFormat
        pcmBufferQueue.sync { pcmBuffer.removeAll(keepingCapacity: true) }
        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.handleTap(buffer: buffer, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()

        startedAt = Date()
        isRecording = true
        let t = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickElapsed() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        let ct = Timer(timeInterval: chunkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.fireChunk() }
        }
        RunLoop.main.add(ct, forMode: .common)
        chunkTimer = ct
    }

    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return outputURL }
        chunkTimer?.invalidate()
        chunkTimer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        audioFile = nil
        targetFormat = nil
        pcmBufferQueue.sync { pcmBuffer.removeAll(keepingCapacity: false) }
        let url = outputURL
        outputURL = nil
        return url
    }

    private func fireChunk() {
        guard let callback = onChunk, let format = targetFormat else { return }
        let snapshot: [Float] = pcmBufferQueue.sync { pcmBuffer }
        guard !snapshot.isEmpty else { return }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            let file = try AVAudioFile(forWriting: tmp, settings: fileSettings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buf = AVAudioPCMBuffer(pcmFormat: format,
                                             frameCapacity: AVAudioFrameCount(snapshot.count)) else { return }
            buf.frameLength = AVAudioFrameCount(snapshot.count)
            if let dst = buf.floatChannelData?[0] {
                snapshot.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: snapshot.count)
                }
            }
            try file.write(from: buf)
            // file deinits here, finalizing the WAV header
            callback(tmp)
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            Task { @MainActor in self.lastError = "Chunk export: \(error.localizedDescription)" }
        }
    }

    private func handleTap(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter, let audioFile else { return }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                  frameCapacity: outputCapacity) else { return }

        var consumed = false
        var convError: NSError?
        let status = converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }

        if status == .error || convError != nil {
            Task { @MainActor in
                self.lastError = convError?.localizedDescription ?? "Audio conversion failed"
            }
            return
        }

        if outputBuffer.frameLength > 0 {
            do {
                try audioFile.write(from: outputBuffer)
            } catch {
                Task { @MainActor in self.lastError = error.localizedDescription }
            }
            appendToPCMBuffer(outputBuffer)
            updateLevel(from: outputBuffer)
        }
    }

    private func appendToPCMBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        let samples = Array(UnsafeBufferPointer(start: channelData, count: frames))
        pcmBufferQueue.sync { pcmBuffer.append(contentsOf: samples) }
    }

    private func updateLevel(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData?[0] else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        var sum: Float = 0
        for i in 0..<frames {
            let s = channelData[i]
            sum += s * s
        }
        let rms = sqrt(sum / Float(frames))
        Task { @MainActor in
            self.level = min(1, max(0, rms * 4))
        }
    }

    private func tickElapsed() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
    }
}
