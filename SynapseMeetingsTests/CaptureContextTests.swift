import XCTest
import AVFoundation
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
}
