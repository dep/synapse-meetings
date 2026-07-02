import Foundation
import AVFoundation
import CoreAudio
import AudioToolbox
import Combine

private extension AVAuthorizationStatus {
    var isMicrophoneGranted: Bool { self == .authorized }
}

/// How CaptureContext interprets incoming buffer channels.
enum CaptureLayout {
    /// Everything downmixed to one channel (existing behavior).
    case mono
    /// Dual-track: input channels 0..<micChannels average → L ("You"),
    /// remaining channels (the system-audio tap) average → R ("Them").
    case dualTrack(micChannels: Int)
}

/// Owns all state the AVAudioEngine tap touches. The tap closure holds the only
/// strong reference besides AudioRecorder. Every member is guarded by `lock` so
/// the render thread and main thread never race; `finish()` makes teardown safe
/// even if a tap callback is mid-flight.
///
/// `converter` is optional: when nil, the input buffer is assumed to already be
/// in `targetFormat` and is written directly (used in tests with identical in/out
/// formats, since AVAudioConverter with same-format in/out can be unreliable).
final class CaptureContext: @unchecked Sendable {
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private let converter: AVAudioConverter?
    let targetFormat: AVAudioFormat
    private let layout: CaptureLayout
    /// Samples accumulated since the last chunk drain (not the full session).
    /// Bounds memory to one chunk interval (~10 s ≈ 640 KB at 16 kHz mono Float32).
    private var pcmBuffer: [Float] = []
    private var finished = false

    init(audioFile: AVAudioFile, converter: AVAudioConverter?, targetFormat: AVAudioFormat,
         layout: CaptureLayout = .mono) {
        self.audioFile = audioFile
        self.converter = converter
        self.targetFormat = targetFormat
        self.layout = layout
    }

    /// Called on the render thread with the raw input buffer.
    /// Returns the raw RMS level (nil if no frames/error/finished) and an error
    /// string for the UI (nil on success). The caller applies `min(1, max(0, rms * 4))`
    /// scaling to the returned level value.
    func ingest(buffer rawBuffer: AVAudioPCMBuffer) -> (level: Float?, error: String?) {
        lock.lock()
        defer { lock.unlock() }

        guard !finished, audioFile != nil else { return (nil, nil) }

        // Route the buffer according to the layout.
        let buffer: AVAudioPCMBuffer
        switch layout {
        case .mono:
            buffer = rawBuffer
        case .dualTrack(let micChannels):
            guard let routed = Self.routeToStereo(buffer: rawBuffer, micChannels: micChannels) else {
                return (nil, nil)
            }
            buffer = routed
        }

        // If no converter, write the buffer directly (input already in target format).
        guard let converter else {
            guard buffer.frameLength > 0 else { return (nil, nil) }
            do {
                try audioFile!.write(from: buffer)
            } catch {
                return (nil, error.localizedDescription)
            }
            appendSamples(from: buffer)
            let rms = computeRMS(from: buffer)
            return (rms, nil)
        }

        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let outputCapacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat,
                                                  frameCapacity: outputCapacity) else {
            return (nil, nil)
        }

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
            return (nil, convError?.localizedDescription ?? "Audio conversion failed")
        }

        guard outputBuffer.frameLength > 0 else { return (nil, nil) }

        do {
            try audioFile!.write(from: outputBuffer)
        } catch {
            return (nil, error.localizedDescription)
        }

        appendSamples(from: outputBuffer)
        let rms = computeRMS(from: outputBuffer)
        return (rms, nil)
    }

    /// Main thread: snapshot samples for chunk export.
    func snapshotSamples() -> [Float] {
        lock.withLock { pcmBuffer }
    }

    /// Main thread: remove and return all samples accumulated since the last drain.
    /// Bounds memory to one chunk interval (~10 s ≈ 640 KB at 16 kHz mono Float32).
    func drainSamples() -> [Float] {
        lock.withLock {
            let s = pcmBuffer
            pcmBuffer.removeAll(keepingCapacity: true)
            return s
        }
    }

    /// Main thread: stop accepting buffers and close the file.
    func finish() {
        lock.withLock {
            finished = true
            audioFile = nil
        }
    }

    // MARK: - Private helpers (called under lock)

    private func appendSamples(from buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else { return }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return }
        if buffer.format.channelCount >= 2 {
            // Dual-track: live chunks carry the mono mix of both sides.
            var mixed = [Float](repeating: 0, count: frames)
            for i in 0..<frames {
                mixed[i] = (channelData[0][i] + channelData[1][i]) * 0.5
            }
            pcmBuffer.append(contentsOf: mixed)
        } else {
            let samples = Array(UnsafeBufferPointer(start: channelData[0], count: frames))
            pcmBuffer.append(contentsOf: samples)
        }
    }

    private func computeRMS(from buffer: AVAudioPCMBuffer) -> Float? {
        guard let channelData = buffer.floatChannelData?[0] else { return nil }
        let frames = Int(buffer.frameLength)
        guard frames > 0 else { return nil }
        var sum: Float = 0
        for i in 0..<frames {
            let s = channelData[i]
            sum += s * s
        }
        return sqrt(sum / Float(frames))
    }

    /// Collapse an N-channel aggregate buffer to stereo: mic channels average → L,
    /// tap channels average → R. Same sample rate; conversion happens downstream.
    private static func routeToStereo(buffer: AVAudioPCMBuffer, micChannels: Int) -> AVAudioPCMBuffer? {
        guard let src = buffer.floatChannelData else { return nil }
        let totalChannels = Int(buffer.format.channelCount)
        let frames = Int(buffer.frameLength)
        let mics = min(max(micChannels, 1), totalChannels)
        let systemChannels = totalChannels - mics
        guard frames > 0 else { return nil }
        guard let stereoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: buffer.format.sampleRate,
                                               channels: 2,
                                               interleaved: false),
              let out = AVAudioPCMBuffer(pcmFormat: stereoFormat,
                                         frameCapacity: AVAudioFrameCount(frames)),
              let dst = out.floatChannelData else { return nil }
        out.frameLength = AVAudioFrameCount(frames)
        for f in 0..<frames {
            var l: Float = 0
            for c in 0..<mics { l += src[c][f] }
            dst[0][f] = l / Float(mics)
            var r: Float = 0
            if systemChannels > 0 {
                for c in mics..<totalChannels { r += src[c][f] }
                r /= Float(systemChannels)
            }
            dst[1][f] = r
        }
        return out
    }
}

@MainActor
final class AudioRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var level: Float = 0
    @Published private(set) var lastError: String?

    private let engine = AVAudioEngine()
    private var captureContext: CaptureContext?
    private var startedAt: Date?
    private var timer: Timer?
    private var outputURL: URL?

    private let targetSampleRate: Double = 16_000
    private let targetChannels: AVAudioChannelCount = 1

    /// Called periodically with a snapshot URL of audio written so far.
    var onChunk: ((URL) -> Void)?
    private var chunkTimer: Timer?
    private let chunkInterval: TimeInterval = 10

    /// UID of the preferred input device. Empty / unresolvable means use the system default.
    var preferredInputDeviceUID: String = ""

    /// Whether the next recording should also capture system audio (set from
    /// AppState's setting before start()). Actual availability is reported via
    /// `systemAudioActive` / `systemAudioNotice`.
    var systemAudioEnabled = false
    /// True while the in-flight recording is dual-track (mic + system tap).
    @Published private(set) var systemAudioActive = false
    /// Non-blocking user-facing note when system capture was requested but
    /// unavailable (unsupported OS, permission denied, tap failure).
    @Published private(set) var systemAudioNotice: String?
    /// Typed Any so the class compiles on macOS 14.0 (SystemAudioTap is 14.4+).
    private var systemTap: Any?

    /// Request microphone permission once at app launch. Safe to call repeatedly —
    /// the OS shows the dialog only on the first call when status is `.notDetermined`.
    func requestMicrophonePermissionIfNeeded() async {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        guard status == .notDetermined else { return }
        _ = await AVCaptureDevice.requestAccess(for: .audio)
    }

    func start(writingTo url: URL) throws {
        if isRecording {
            throw NSError(
                domain: "AudioRecorder",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Already recording"]
            )
        }

        guard AVCaptureDevice.authorizationStatus(for: .audio).isMicrophoneGranted else {
            throw NSError(
                domain: "AudioRecorder",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Microphone access is required to record. Please grant access in System Settings → Privacy & Security → Microphone."]
            )
        }
        lastError = nil
        outputURL = url

        systemAudioNotice = nil
        systemAudioActive = false
        var layout: CaptureLayout = .mono
        if systemAudioEnabled {
            if #available(macOS 14.4, *) {
                do {
                    let tap = SystemAudioTap()
                    let activation = try tap.activate(preferredMicUID: preferredInputDeviceUID)
                    guard setEngineInputDevice(activation.aggregateID) else {
                        tap.teardown()
                        throw NSError(domain: "AudioRecorder", code: 3,
                                      userInfo: [NSLocalizedDescriptionKey: "Could not select capture aggregate device"])
                    }
                    systemTap = tap
                    layout = .dualTrack(micChannels: activation.micChannelCount)
                    systemAudioActive = true
                } catch {
                    NSLog("AudioRecorder: system audio capture unavailable — \(error.localizedDescription)")
                    systemAudioNotice = "System audio unavailable — recording microphone only"
                }
            } else {
                systemAudioNotice = "System audio capture requires macOS 14.4 or later"
            }
        }
        if !systemAudioActive {
            applyPreferredInputDevice()
        }

        let input = engine.inputNode
        input.removeTap(onBus: 0)
        if engine.isRunning {
            engine.stop()
        }
        engine.reset()

        let inputFormat = input.outputFormat(forBus: 0)

        let outputChannels: AVAudioChannelCount = systemAudioActive ? 2 : targetChannels
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: outputChannels,
            interleaved: false
        ) else {
            throw NSError(domain: "AudioRecorder", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not build target audio format"])
        }

        // AVAudioFile written in target format (16kHz mono/stereo Float32 WAV)
        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: targetSampleRate,
            AVNumberOfChannelsKey: outputChannels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: fileSettings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)

        let converterInputFormat: AVAudioFormat
        switch layout {
        case .mono:
            converterInputFormat = inputFormat
        case .dualTrack:
            // CaptureContext routes N-channel aggregate buffers to stereo before
            // conversion, so the converter's input side is stereo at the device rate.
            guard let stereoIn = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                               sampleRate: inputFormat.sampleRate,
                                               channels: 2,
                                               interleaved: false) else {
                throw NSError(domain: "AudioRecorder", code: -1,
                              userInfo: [NSLocalizedDescriptionKey: "Could not build routed stereo format"])
            }
            converterInputFormat = stereoIn
        }
        let converter = AVAudioConverter(from: converterInputFormat, to: targetFormat)

        let context = CaptureContext(audioFile: file, converter: converter,
                                     targetFormat: targetFormat, layout: layout)
        captureContext = context

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            let outcome = context.ingest(buffer: buffer)
            if outcome.level != nil || outcome.error != nil {
                Task { @MainActor in
                    if let lvl = outcome.level { self?.level = min(1, max(0, lvl * 4)) }
                    if let err = outcome.error { self?.lastError = err }
                }
            }
        }

        engine.prepare()
        try engine.start()

        startedAt = Date()
        elapsed = 0
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
        // removeTap/stop before finish so no new callbacks arrive after finish().
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()
        timer?.invalidate()
        timer = nil
        isRecording = false
        captureContext?.finish()
        captureContext = nil
        if #available(macOS 14.4, *), let tap = systemTap as? SystemAudioTap {
            tap.teardown()
        }
        systemTap = nil
        systemAudioActive = false
        let url = outputURL
        outputURL = nil
        return url
    }

    private func fireChunk() {
        guard let callback = onChunk, let context = captureContext else { return }
        let format = context.targetFormat
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: format.sampleRate,
                                             channels: 1,
                                             interleaved: false) else { return }
        let snapshot = context.drainSamples()
        guard !snapshot.isEmpty else { return }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let fileSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: monoFormat.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            let file = try AVAudioFile(forWriting: tmp, settings: fileSettings,
                                       commonFormat: .pcmFormatFloat32, interleaved: false)
            guard let buf = AVAudioPCMBuffer(pcmFormat: monoFormat,
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

    private func tickElapsed() {
        guard let startedAt else { return }
        elapsed = Date().timeIntervalSince(startedAt)
    }

    // MARK: - Input device selection

    private func applyPreferredInputDevice() {
        let uid = preferredInputDeviceUID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !uid.isEmpty else { return } // empty = system default; nothing to do.

        guard let deviceID = audioDeviceID(forUID: uid) else {
            NSLog("AudioRecorder: preferred input device UID '\(uid)' not currently connected — using system default")
            return
        }
        setEngineInputDevice(deviceID)
    }

    /// Points the engine's input AudioUnit at a specific device (mic or aggregate).
    @discardableResult
    private func setEngineInputDevice(_ deviceID: AudioDeviceID) -> Bool {
        guard let unit = engine.inputNode.audioUnit else {
            NSLog("AudioRecorder: inputNode.audioUnit is nil; cannot override input device")
            return false
        }
        var id = deviceID
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &id,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            NSLog("AudioRecorder: AudioUnitSetProperty(CurrentDevice) failed (status \(status))")
            return false
        }
        return true
    }

    private func audioDeviceID(forUID uid: String) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfUID = uid as CFString
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr -> OSStatus in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<CFString>.size),
                uidPtr,
                &size,
                &deviceID
            )
        }
        guard status == noErr, deviceID != 0 else { return nil }
        return deviceID
    }
}
