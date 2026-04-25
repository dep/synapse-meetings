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

    private let targetSampleRate: Double = 16_000
    private let targetChannels: AVAudioChannelCount = 1

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
    }

    @discardableResult
    func stop() -> URL? {
        guard isRecording else { return outputURL }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        timer?.invalidate()
        timer = nil
        isRecording = false
        audioFile = nil
        let url = outputURL
        outputURL = nil
        return url
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
            updateLevel(from: outputBuffer)
        }
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
