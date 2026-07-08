import XCTest
import AVFoundation
import CoreAudio
@testable import Synapse_Meetings

// MARK: - Helpers

private func makeSineBuffer(format: AVAudioFormat, frameCount: Int) -> AVAudioPCMBuffer {
    let buf = AVAudioPCMBuffer(pcmFormat: format,
                               frameCapacity: AVAudioFrameCount(frameCount))!
    buf.frameLength = AVAudioFrameCount(frameCount)
    if let ch = buf.floatChannelData?[0] {
        for i in 0..<frameCount {
            ch[i] = sin(Float(i) * 0.1)
        }
    }
    return buf
}

/// Multichannel buffer where every frame of channel c equals `values[c]`.
/// Constant per-channel values make routing assertions exact.
private func makeConstantBuffer(format: AVAudioFormat, frameCount: Int, values: [Float]) -> AVAudioPCMBuffer {
    let buf = AVAudioPCMBuffer(pcmFormat: format,
                               frameCapacity: AVAudioFrameCount(frameCount))!
    buf.frameLength = AVAudioFrameCount(frameCount)
    for c in 0..<Int(format.channelCount) {
        if let ch = buf.floatChannelData?[c] {
            for i in 0..<frameCount { ch[i] = values[c] }
        }
    }
    return buf
}

private func makeTargetFormat() -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: 16_000,
                  channels: 1,
                  interleaved: false)!
}

private func makeTempURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("wav")
}

private func makeAudioFile(at url: URL, format: AVAudioFormat) throws -> AVAudioFile {
    let settings: [String: Any] = [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: format.channelCount,
        AVLinearPCMBitDepthKey: 32,
        AVLinearPCMIsFloatKey: true,
        AVLinearPCMIsNonInterleaved: false,
        AVLinearPCMIsBigEndianKey: false
    ]
    return try AVAudioFile(forWriting: url,
                           settings: settings,
                           commonFormat: .pcmFormatFloat32,
                           interleaved: false)
}

private func makeStereoTargetFormat() -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: 16_000,
                  channels: 2,
                  interleaved: false)!
}

/// >2-channel formats need an explicit stream description AND a channel layout —
/// the convenience AVAudioFormat initializers return nil above stereo without one.
private func makeThreeChannelFormat(sampleRate: Double) -> AVAudioFormat {
    var asbd = AudioStreamBasicDescription(
        mSampleRate: sampleRate,
        mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
        mBytesPerPacket: 4,
        mFramesPerPacket: 1,
        mBytesPerFrame: 4,
        mChannelsPerFrame: 3,
        mBitsPerChannel: 32,
        mReserved: 0
    )
    // MPEG_3_0_A = 3 channels (L R C); any 3-channel tag works — CaptureContext
    // routing only cares about channel indices, not spatial semantics.
    let layout = AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_3_0_A)!
    return AVAudioFormat(streamDescription: &asbd, channelLayout: layout)!
}

// MARK: - Tests

final class CaptureContextTests: XCTestCase {

    // MARK: Test 1: ingest after finish is a no-op

    func testIngestAfterFinish_isNoOp() throws {
        let format = makeTargetFormat()
        let url = makeTempURL()
        let file = try makeAudioFile(at: url, format: format)

        // nil converter = passthrough (input already in target format).
        let ctx = CaptureContext(audioFile: file, converter: nil, targetFormat: format)
        ctx.finish()

        let buf = makeSineBuffer(format: format, frameCount: 64)
        let result = ctx.ingest(buffer: buf)

        XCTAssertNil(result.level, "No level should be returned after finish")
        XCTAssertNil(result.error, "No error should be returned after finish")
        XCTAssertTrue(ctx.snapshotSamples().isEmpty,
                      "snapshotSamples should be empty after finish+ingest")
    }

    // MARK: Test 2: ingest accumulates samples and writes to disk

    func testIngestAccumulatesSamples() throws {
        let format = makeTargetFormat()
        let url = makeTempURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let file = try makeAudioFile(at: url, format: format)
        // nil converter: input is already in target format, written directly.
        let ctx = CaptureContext(audioFile: file, converter: nil, targetFormat: format)

        let buf = makeSineBuffer(format: format, frameCount: 1600)
        let result = ctx.ingest(buffer: buf)

        XCTAssertNil(result.error, "ingest should not error: \(result.error ?? "")")
        XCTAssertNotNil(result.level, "ingest should return a level for a non-silent buffer")

        let samples = ctx.snapshotSamples()
        XCTAssertEqual(samples.count, 1600,
                       "snapshotSamples should contain exactly 1600 frames after one ingest")

        // Close the file (simulates stop()) and check WAV size > header.
        ctx.finish()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? Int ?? 0
        // 44-byte canonical WAV header + 1600 frames * 4 bytes = 6444 bytes minimum.
        XCTAssertGreaterThan(size, 44,
                             "WAV file should be larger than its 44-byte header after writing 1600 frames (got \(size) bytes)")
    }

    // MARK: Test 4: drainSamples empties the in-memory buffer

    func testDrainSamples_emptiesBuffer() throws {
        let format = makeTargetFormat()
        let url = makeTempURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let file = try makeAudioFile(at: url, format: format)
        let ctx = CaptureContext(audioFile: file, converter: nil, targetFormat: format)

        let buf = makeSineBuffer(format: format, frameCount: 1600)
        _ = ctx.ingest(buffer: buf)

        let drained = ctx.drainSamples()
        XCTAssertEqual(drained.left.count, 1600,
                       "drainSamples should return exactly 1600 frames after one ingest")
        XCTAssertTrue(drained.right.isEmpty, "mono layout must not accumulate a right channel")
        XCTAssertFalse(drained.isStereo)

        let second = ctx.drainSamples()
        XCTAssertTrue(second.left.isEmpty,
                      "drainSamples should be empty on a second call with no new ingest")
    }

    // MARK: Test 5: drainSamples does not affect WAV file on disk

    func testDrainSamples_doesNotAffectFileOnDisk() throws {
        let format = makeTargetFormat()
        let url = makeTempURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let file = try makeAudioFile(at: url, format: format)
        let ctx = CaptureContext(audioFile: file, converter: nil, targetFormat: format)

        let buf = makeSineBuffer(format: format, frameCount: 1600)
        _ = ctx.ingest(buffer: buf)

        // Drain the in-memory buffer — should not affect the on-disk file.
        _ = ctx.drainSamples()
        ctx.finish()

        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        let size = attrs[.size] as? Int ?? 0
        // 44-byte canonical WAV header + 1600 frames * 4 bytes = 6444 bytes minimum.
        XCTAssertGreaterThan(size, 44,
                             "WAV file should still contain audio data after drainSamples (got \(size) bytes)")
    }

    // MARK: Test 3: concurrent ingest and finish does not crash

    func testConcurrentIngestAndFinish_doesNotCrash() throws {
        let format = makeTargetFormat()
        let url = makeTempURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let file = try makeAudioFile(at: url, format: format)
        let ctx = CaptureContext(audioFile: file, converter: nil, targetFormat: format)

        let iterations = 100
        var finishCalled = false

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            if i == iterations / 2 && !finishCalled {
                finishCalled = true
                ctx.finish()
            } else {
                let buf = makeSineBuffer(format: format, frameCount: 64)
                _ = ctx.ingest(buffer: buf)
            }
        }

        // Ensure finish was definitely called and a final snapshot doesn't crash.
        if !finishCalled { ctx.finish() }
        let samples = ctx.snapshotSamples()
        // Just assert we got here without crashing; sample count is non-deterministic.
        XCTAssertGreaterThanOrEqual(samples.count, 0,
                                    "snapshotSamples should return without error after concurrent use")
    }

    // MARK: Dual-track layout

    /// 3-channel input (1 mic + 2 tap), constant values: mic=0.5, tapL=0.2, tapR=0.4.
    /// Expect file channel L = 0.5 (mic), R = 0.3 (tap average).
    func testDualTrack_routesMicToLeftAndSystemToRight() throws {
        let inputFormat = makeThreeChannelFormat(sampleRate: 16_000)
        let target = makeStereoTargetFormat()
        let url = makeTempURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        // Scope the writing AVAudioFile so it deallocates (finalizing the WAV
        // header) before we open the same URL for reading below.
        try autoreleasepool {
            let file = try makeAudioFile(at: url, format: target)
            // nil converter: routed stereo is already at the target rate/format.
            let ctx = CaptureContext(audioFile: file, converter: nil, targetFormat: target,
                                     layout: .dualTrack(micChannels: 1))

            let buf = makeConstantBuffer(format: inputFormat, frameCount: 1600,
                                         values: [0.5, 0.2, 0.4])
            let result = ctx.ingest(buffer: buf)
            XCTAssertNil(result.error)
            ctx.finish()
        }

        let readBack = try AVAudioFile(forReading: url)
        XCTAssertEqual(readBack.processingFormat.channelCount, 2)
        let readBuf = AVAudioPCMBuffer(pcmFormat: readBack.processingFormat,
                                       frameCapacity: 1600)!
        try readBack.read(into: readBuf)
        XCTAssertEqual(Int(readBuf.frameLength), 1600)
        XCTAssertEqual(readBuf.floatChannelData![0][0], 0.5, accuracy: 0.001, "L must be the mic channel")
        XCTAssertEqual(readBuf.floatChannelData![1][0], 0.3, accuracy: 0.001, "R must be the averaged tap channels")
    }

    /// drainSamples in dual-track mode returns both channels separately:
    /// L = mic = 0.5, R = tap average = 0.3.
    func testDualTrack_drainReturnsBothChannels() throws {
        let inputFormat = makeThreeChannelFormat(sampleRate: 16_000)
        let target = makeStereoTargetFormat()
        let url = makeTempURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let file = try makeAudioFile(at: url, format: target)
        let ctx = CaptureContext(audioFile: file, converter: nil, targetFormat: target,
                                 layout: .dualTrack(micChannels: 1))

        let buf = makeConstantBuffer(format: inputFormat, frameCount: 800,
                                     values: [0.5, 0.2, 0.4])
        _ = ctx.ingest(buffer: buf)

        let drained = ctx.drainSamples()
        XCTAssertTrue(drained.isStereo)
        XCTAssertEqual(drained.left.count, 800, "drain must return one left sample per frame")
        XCTAssertEqual(drained.right.count, 800, "drain must return one right sample per frame")
        XCTAssertEqual(drained.left[0], 0.5, accuracy: 0.001, "left must be the mic channel")
        XCTAssertEqual(drained.right[0], 0.3, accuracy: 0.001, "right must be the averaged tap channels")
        ctx.finish()
    }

    /// Level (RMS) in dual-track mode reflects the mic (L) channel only:
    /// mic silent + loud tap ⇒ RMS 0.
    func testDualTrack_levelReflectsMicChannelOnly() throws {
        let inputFormat = makeThreeChannelFormat(sampleRate: 16_000)
        let target = makeStereoTargetFormat()
        let url = makeTempURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let file = try makeAudioFile(at: url, format: target)
        let ctx = CaptureContext(audioFile: file, converter: nil, targetFormat: target,
                                 layout: .dualTrack(micChannels: 1))

        let buf = makeConstantBuffer(format: inputFormat, frameCount: 800,
                                     values: [0.0, 0.8, 0.8])
        let result = ctx.ingest(buffer: buf)
        XCTAssertNotNil(result.level)
        XCTAssertEqual(result.level ?? -1, 0, accuracy: 0.001,
                       "level must come from the mic channel, not the tap")
        ctx.finish()
    }
}

// MARK: - Chunk WAV export

final class ChunkWAVTests: XCTestCase {

    func testWriteChunkWAV_stereo_writesBothChannels() throws {
        let samples = DrainedSamples(left: [Float](repeating: 0.5, count: 1600),
                                     right: [Float](repeating: 0.3, count: 1600))
        let url = try AudioRecorder.writeChunkWAV(samples, sampleRate: 16_000)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.channelCount, 2)
        XCTAssertEqual(file.processingFormat.sampleRate, 16_000)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1600)!
        try file.read(into: buf)
        XCTAssertEqual(Int(buf.frameLength), 1600)
        XCTAssertEqual(buf.floatChannelData![0][0], 0.5, accuracy: 0.001, "L = mic samples")
        XCTAssertEqual(buf.floatChannelData![1][0], 0.3, accuracy: 0.001, "R = system samples")
        XCTAssertEqual(buf.floatChannelData![0][1599], 0.5, accuracy: 0.001, "last frame intact")
    }

    func testWriteChunkWAV_mono_writesSingleChannel() throws {
        let samples = DrainedSamples(left: [Float](repeating: 0.4, count: 800), right: [])
        let url = try AudioRecorder.writeChunkWAV(samples, sampleRate: 16_000)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 800)!
        try file.read(into: buf)
        XCTAssertEqual(Int(buf.frameLength), 800)
        XCTAssertEqual(buf.floatChannelData![0][0], 0.4, accuracy: 0.001)
    }

    /// The IOProc can deliver a torn final buffer; a short right channel must not
    /// crash or shift frames — it is zero-padded to the left channel's length.
    func testWriteChunkWAV_shortRightChannel_zeroPads() throws {
        let samples = DrainedSamples(left: [Float](repeating: 0.5, count: 100),
                                     right: [Float](repeating: 0.3, count: 60))
        let url = try AudioRecorder.writeChunkWAV(samples, sampleRate: 16_000)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let file = try AVAudioFile(forReading: url)
        let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 100)!
        try file.read(into: buf)
        XCTAssertEqual(Int(buf.frameLength), 100)
        XCTAssertEqual(buf.floatChannelData![1][59], 0.3, accuracy: 0.001)
        XCTAssertEqual(buf.floatChannelData![1][60], 0.0, accuracy: 0.001, "missing right samples are silence")
    }
}

// MARK: - makeCombinedBuffer (IOProc AudioBufferList -> non-interleaved PCM)

final class CombinedBufferTests: XCTestCase {

    /// Builds an ABL like a mic+tap aggregate IOProc delivers: stream 0 = mono mic,
    /// stream 1 = stereo tap (interleaved within the stream buffer).
    private func makeTwoStreamABL(frames: Int, mic: Float, tapL: Float, tapR: Float)
        -> (UnsafeMutablePointer<AudioBufferList>, [UnsafeMutableRawPointer]) {
        let abl = AudioBufferList.allocate(maximumBuffers: 2)
        let micBytes = frames * MemoryLayout<Float>.size
        let tapBytes = frames * 2 * MemoryLayout<Float>.size
        let micData = UnsafeMutableRawPointer.allocate(byteCount: micBytes, alignment: 16)
        let tapData = UnsafeMutableRawPointer.allocate(byteCount: tapBytes, alignment: 16)
        let micPtr = micData.bindMemory(to: Float.self, capacity: frames)
        let tapPtr = tapData.bindMemory(to: Float.self, capacity: frames * 2)
        for i in 0..<frames {
            micPtr[i] = mic
            tapPtr[i * 2] = tapL
            tapPtr[i * 2 + 1] = tapR
        }
        abl[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(micBytes), mData: micData)
        abl[1] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(tapBytes), mData: tapData)
        return (abl.unsafeMutablePointer, [micData, tapData])
    }

    func testCombine_twoStreams_deinterleavesIntoThreeChannels() {
        let (abl, raw) = makeTwoStreamABL(frames: 480, mic: 0.5, tapL: 0.2, tapR: 0.4)
        defer { raw.forEach { $0.deallocate() }; free(abl) }

        let buf = CaptureContext.makeCombinedBuffer(from: abl, sampleRate: 48_000)
        XCTAssertNotNil(buf)
        guard let buf else { return }
        XCTAssertEqual(buf.format.channelCount, 3)
        XCTAssertEqual(Int(buf.frameLength), 480)
        XCTAssertEqual(buf.format.sampleRate, 48_000)
        XCTAssertFalse(buf.format.isInterleaved)
        XCTAssertEqual(buf.floatChannelData![0][0], 0.5, accuracy: 0.0001, "ch0 = mic stream")
        XCTAssertEqual(buf.floatChannelData![1][0], 0.2, accuracy: 0.0001, "ch1 = tap L (deinterleaved)")
        XCTAssertEqual(buf.floatChannelData![2][0], 0.4, accuracy: 0.0001, "ch2 = tap R (deinterleaved)")
        XCTAssertEqual(buf.floatChannelData![1][479], 0.2, accuracy: 0.0001, "last frame intact")
    }

    /// Combined buffer feeds the existing dual-track routing: mic -> L, tap avg -> R.
    func testCombine_thenDualTrackIngest_routesCorrectly() throws {
        let (abl, raw) = makeTwoStreamABL(frames: 480, mic: 0.5, tapL: 0.2, tapR: 0.4)
        defer { raw.forEach { $0.deallocate() }; free(abl) }
        guard let combined = CaptureContext.makeCombinedBuffer(from: abl, sampleRate: 16_000) else {
            return XCTFail("combine failed")
        }

        let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
                                   channels: 2, interleaved: false)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let ctx = CaptureContext(audioFile: file, converter: nil, targetFormat: target,
                                 layout: .dualTrack(micChannels: 1))
        let outcome = ctx.ingest(buffer: combined)
        XCTAssertNil(outcome.error)
        let drained = ctx.drainSamples()
        XCTAssertEqual(drained.left.count, 480)
        XCTAssertEqual(drained.right.count, 480)
        XCTAssertEqual(drained.left[0], 0.5, accuracy: 0.001, "L = mic stream")
        XCTAssertEqual(drained.right[0], 0.3, accuracy: 0.001, "R = tap average")
        ctx.finish()
    }

    func testCombine_zeroFrames_returnsNil() {
        let (abl, raw) = makeTwoStreamABL(frames: 0, mic: 0, tapL: 0, tapR: 0)
        defer { raw.forEach { $0.deallocate() }; free(abl) }
        XCTAssertNil(CaptureContext.makeCombinedBuffer(from: abl, sampleRate: 48_000))
    }
}
