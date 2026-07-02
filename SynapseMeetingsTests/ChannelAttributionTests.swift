import XCTest
import AVFoundation
import FluidAudio
@testable import Synapse_Meetings

final class ChannelAttributionTests: XCTestCase {

    // MARK: - Helpers

    private func makeToken(_ text: String, start: Double, end: Double) -> TokenTiming {
        TokenTiming(token: text, tokenId: 0, startTime: start, endTime: end, confidence: 1.0)
    }

    private func makeSegment(_ speakerId: String, start: Float, end: Float) -> TimedSpeakerSegment {
        TimedSpeakerSegment(
            speakerId: speakerId,
            embedding: [],
            startTimeSeconds: start,
            endTimeSeconds: end,
            qualityScore: 1.0
        )
    }

    /// Stereo 16 kHz WAV: seconds 0–1 mic-only tone, seconds 1–2 system-only tone.
    private func writeStereoFixture() throws -> URL {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000, channels: 2, interleaved: false)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
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
        let frames = 32_000 // 2 seconds
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let tone = sin(Float(i) * 0.2) * 0.5
            buf.floatChannelData![0][i] = i < 16_000 ? tone : 0   // L: mic speaks 0–1s
            buf.floatChannelData![1][i] = i < 16_000 ? 0 : tone   // R: system speaks 1–2s
        }
        try file.write(from: buf)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    // MARK: - ChannelEnvelopes

    func testLoad_stereoFile_sourcesFollowEnergy() throws {
        let url = try writeStereoFixture()
        let env = try ChannelEnvelopes.load(from: url)
        XCTAssertTrue(env.isStereo)
        XCTAssertEqual(env.source(start: 0.2, end: 0.6), .mic)
        XCTAssertEqual(env.source(start: 1.2, end: 1.6), .system)
    }

    func testLoad_monoFile_isNotStereo() throws {
        // Mono fixture: same writer, 1 channel.
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                   sampleRate: 16_000, channels: 1, interleaved: false)!
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("wav")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!
        buf.frameLength = 1600
        try file.write(from: buf)

        let env = try ChannelEnvelopes.load(from: url)
        XCTAssertFalse(env.isStereo)
    }

    /// Spec tie-break: both channels hot ⇒ system wins (mic bleed on speakers).
    func testSource_bothChannelsHot_systemWins() {
        let env = ChannelEnvelopes(left: [0.5, 0.5], right: [0.4, 0.4], windowDuration: 0.5)
        XCTAssertEqual(env.source(start: 0.0, end: 1.0), .system)
    }

    func testSource_micDominates_micWins() {
        let env = ChannelEnvelopes(left: [0.5, 0.5], right: [0.01, 0.01], windowDuration: 0.5)
        XCTAssertEqual(env.source(start: 0.0, end: 1.0), .mic)
    }

    // MARK: - writeSystemChannel

    func testWriteSystemChannel_extractsRightChannelAsMono() throws {
        let url = try writeStereoFixture()
        let monoURL = try ChannelEnvelopes.writeSystemChannel(from: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: monoURL) }

        let file = try AVAudioFile(forReading: monoURL)
        XCTAssertEqual(file.processingFormat.channelCount, 1)
        // The system channel is silent for the first second, hot in the second.
        let env = try ChannelEnvelopes.load(from: monoURL)
        let early = env.left[0..<10].reduce(0, +)
        let late = env.left[(env.left.count - 10)...].reduce(0, +)
        XCTAssertLessThan(early, 0.001)
        XCTAssertGreaterThan(late, 0.1)
    }

    // MARK: - attributeTokensToChannels

    @MainActor
    func testAttribute_withoutSegments_labelsYouAndThem() {
        let env = ChannelEnvelopes(
            left:  [0.5, 0.5, 0.0, 0.0],   // mic speaks 0–1s
            right: [0.0, 0.0, 0.5, 0.5],   // system speaks 1–2s
            windowDuration: 0.5
        )
        let tokens = [
            makeToken("▁Hi", start: 0.1, end: 0.4),
            makeToken("▁there", start: 0.5, end: 0.9),
            makeToken("▁Hello", start: 1.1, end: 1.5),
            makeToken("▁back", start: 1.6, end: 1.9)
        ]
        let turns = AppState.attributeTokensToChannels(tokens: tokens, envelopes: env,
                                                       systemSegments: nil)
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[0].speakerLabel, "You")
        XCTAssertEqual(turns[0].text, "Hi there")
        XCTAssertEqual(turns[1].speakerLabel, "Them")
        XCTAssertEqual(turns[1].text, "Hello back")
    }

    @MainActor
    func testAttribute_withSegments_labelsRemoteSpeakers() {
        let env = ChannelEnvelopes(
            left:  [0.5, 0.0, 0.0, 0.0],
            right: [0.0, 0.5, 0.5, 0.5],
            windowDuration: 0.5
        )
        let tokens = [
            makeToken("▁Hi", start: 0.1, end: 0.4),      // mic → You
            makeToken("▁Hello", start: 0.6, end: 0.9),   // system, segment A
            makeToken("▁Hey", start: 1.6, end: 1.9)      // system, segment B
        ]
        let segments = [
            makeSegment("spk_a", start: 0.5, end: 1.0),
            makeSegment("spk_b", start: 1.5, end: 2.0)
        ]
        let turns = AppState.attributeTokensToChannels(tokens: tokens, envelopes: env,
                                                       systemSegments: segments)
        XCTAssertEqual(turns.map(\.speakerLabel), ["You", "Speaker 1", "Speaker 2"])
    }

    @MainActor
    func testAttribute_emptyTokens_returnsEmpty() {
        let env = ChannelEnvelopes(left: [0.5], right: [0.5], windowDuration: 0.5)
        XCTAssertTrue(AppState.attributeTokensToChannels(tokens: [], envelopes: env,
                                                         systemSegments: nil).isEmpty)
    }
}
