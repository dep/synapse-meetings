import Foundation
import AVFoundation

/// Which physical source a stretch of audio came from in a dual-track recording.
enum AudioSource {
    case mic
    case system
}

/// Windowed per-channel RMS envelopes of a recording WAV (L = mic, R = system),
/// used to attribute transcript tokens to "You" vs "Them" without holding raw
/// samples in memory (a 1-hour stereo file is ~460 MB of floats; the envelope
/// at 50 ms windows is ~280 KB).
struct ChannelEnvelopes {
    let left: [Float]
    let right: [Float]
    let windowDuration: Double

    /// False for mono (mic-only) files — attribution is skipped for those.
    var isStereo: Bool { !right.isEmpty }

    /// Decide the source for a token window. The system channel wins whenever it
    /// carries comparable energy: with headphones the mic never hears the remote
    /// side, and without headphones a hot mic during remote speech is bleed
    /// (spec tie-break: both hot → Them).
    func source(start: Double, end: Double) -> AudioSource {
        let l = averageRMS(left, start: start, end: end)
        let r = averageRMS(right, start: start, end: end)
        return r >= l * 0.5 ? .system : .mic
    }

    private func averageRMS(_ envelope: [Float], start: Double, end: Double) -> Float {
        guard !envelope.isEmpty, windowDuration > 0 else { return 0 }
        let lo = max(0, min(Int(start / windowDuration), envelope.count - 1))
        let hi = max(lo, min(Int(end / windowDuration), envelope.count - 1))
        var sum: Float = 0
        for i in lo...hi { sum += envelope[i] }
        return sum / Float(hi - lo + 1)
    }

    /// Streaming read (64k-frame chunks) so large files never land in memory.
    static func load(from url: URL, windowDuration: Double = 0.05) throws -> ChannelEnvelopes {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let channels = Int(format.channelCount)
        let framesPerWindow = max(1, Int(format.sampleRate * windowDuration))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 65_536) else {
            throw NSError(domain: "ChannelAttribution", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate read buffer"])
        }

        var left: [Float] = []
        var right: [Float] = []
        var sumL: Float = 0
        var sumR: Float = 0
        var windowFill = 0

        while file.framePosition < file.length {
            try file.read(into: buffer)
            let frames = Int(buffer.frameLength)
            guard frames > 0, let data = buffer.floatChannelData else { break }
            for f in 0..<frames {
                let l = data[0][f]
                sumL += l * l
                if channels >= 2 {
                    let r = data[1][f]
                    sumR += r * r
                }
                windowFill += 1
                if windowFill == framesPerWindow {
                    left.append(sqrt(sumL / Float(framesPerWindow)))
                    if channels >= 2 { right.append(sqrt(sumR / Float(framesPerWindow))) }
                    sumL = 0; sumR = 0; windowFill = 0
                }
            }
        }
        if windowFill > 0 {
            left.append(sqrt(sumL / Float(windowFill)))
            if channels >= 2 { right.append(sqrt(sumR / Float(windowFill))) }
        }
        return ChannelEnvelopes(left: left, right: right, windowDuration: windowDuration)
    }

    /// Extracts the system (right) channel to a temp mono WAV at the file's own
    /// sample rate, for diarizing only the remote side. Caller deletes the file.
    static func writeSystemChannel(from url: URL) throws -> URL {
        let inFile = try AVAudioFile(forReading: url)
        let inFormat = inFile.processingFormat
        guard inFormat.channelCount >= 2 else {
            throw NSError(domain: "ChannelAttribution", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Recording is not dual-track"])
        }
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: inFormat.sampleRate,
                                             channels: 1,
                                             interleaved: false),
              let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 65_536),
              let outBuf = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 65_536) else {
            throw NSError(domain: "ChannelAttribution", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not allocate channel-extract buffers"])
        }

        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: inFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let outFile = try AVAudioFile(forWriting: outURL, settings: settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)

        while inFile.framePosition < inFile.length {
            try inFile.read(into: inBuf)
            let frames = Int(inBuf.frameLength)
            guard frames > 0,
                  let src = inBuf.floatChannelData,
                  let dst = outBuf.floatChannelData else { break }
            outBuf.frameLength = AVAudioFrameCount(frames)
            dst[0].update(from: src[1], count: frames)
            try outFile.write(from: outBuf)
        }
        return outURL
    }
}
