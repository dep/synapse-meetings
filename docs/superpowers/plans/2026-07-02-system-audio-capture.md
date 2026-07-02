# System Audio Capture (Dual-Track "You / Them") Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Record system audio output (Zoom/Meet/Teams — the remote side of a call) alongside the microphone so headphone meetings capture both sides, with transcript speech labeled **You** (mic) vs **Them** (system audio).

**Architecture:** A Core Audio **process tap** over the global output mixdown is bundled with the mic into one **aggregate device** (drift-compensated → sample-aligned). `AudioRecorder`'s existing `AVAudioEngine` points at the aggregate and writes a **stereo** 16 kHz WAV (L = mic, R = system). The pipeline attributes ASR tokens to channels by RMS energy; diarization (when on) runs on the system channel only, so remote speakers cluster cleanly while the user is always "You".

**Tech Stack:** Swift 5.10, AVFoundation/CoreAudio (`CATapDescription`, `AudioHardwareCreateProcessTap`, `AudioHardwareCreateAggregateDevice`), FluidAudio (ASR + diarization), XcodeGen + xcodebuild, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-02-system-audio-capture-design.md`

## Global Constraints

- Deployment target stays **macOS 14.0**; all tap code is `@available(macOS 14.4, *)`-gated. Below 14.4 → today's mic-only behavior.
- **Fallback rule:** any tap/aggregate/permission failure degrades to mic-only mono recording with a non-blocking notice. Recording must never be blocked by this feature.
- File format: one WAV per recording at the existing path; **stereo (L=mic, R=system)** when system capture is active, mono otherwise. 16 kHz Float32, same as today.
- Live-transcript chunk WAVs remain **mono** (mix of both channels).
- Attribution tie-break: when both channels are hot, **system (Them) wins**.
- After any `project.yml` edit: run `xcodegen generate` before building/testing.
- Build app once before CLI tests (test bundle's `TEST_HOST` is the built .app).
- Test command: `xcodebuild test -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS' -only-testing:SynapseMeetingsTests/<ClassName>`
- Commit style: short conventional messages (`feat:`, `test:`, `chore:`).

---

### Task 1: `Recording.hasSystemAudio` model flag

**Files:**
- Modify: `SynapseMeetings/Models/Recording.swift`
- Test: `SynapseMeetingsTests/RecordingModelTests.swift`

**Interfaces:**
- Produces: `Recording.hasSystemAudio: Bool` (init param, default `false`; decodes to `false` when absent). Used by Task 6 (pipeline) and Task 7 (start wiring).

- [ ] **Step 1: Write the failing tests**

Append to `SynapseMeetingsTests/RecordingModelTests.swift` (inside the existing test class):

```swift
    func testDecode_missingHasSystemAudio_defaultsFalse() throws {
        // Encode a recording, strip the new key, decode — simulates pre-existing JSON.
        let rec = Recording(audioFilename: "a.wav")
        let data = try JSONEncoder().encode(rec)
        var dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        dict.removeValue(forKey: "hasSystemAudio")
        let stripped = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(Recording.self, from: stripped)
        XCTAssertFalse(decoded.hasSystemAudio)
    }

    func testHasSystemAudio_roundTrips() throws {
        var rec = Recording(audioFilename: "a.wav")
        rec.hasSystemAudio = true
        let data = try JSONEncoder().encode(rec)
        let decoded = try JSONDecoder().decode(Recording.self, from: data)
        XCTAssertTrue(decoded.hasSystemAudio)
    }
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project SynapseMeetings.xcodeproj -scheme SynapseMeetings \
  -destination 'platform=macOS' -only-testing:SynapseMeetingsTests/RecordingModelTests
```
Expected: **compile error** — `Recording` has no member `hasSystemAudio`.

- [ ] **Step 3: Implement**

In `SynapseMeetings/Models/Recording.swift`:

1. Add the stored property after `var speakerTurns: [SpeakerTurn]`:

```swift
    /// True when this recording's WAV is dual-track: L = microphone ("You"),
    /// R = system-audio tap ("Them"). Drives channel attribution in the pipeline.
    var hasSystemAudio: Bool
```

2. Add init parameter `hasSystemAudio: Bool = false` (after `speakerTurns: [SpeakerTurn] = []`) and assign `self.hasSystemAudio = hasSystemAudio` in the init body.

3. In `init(from decoder:)`, after the `speakerTurns` line:

```swift
        hasSystemAudio = try c.decodeIfPresent(Bool.self, forKey: .hasSystemAudio) ?? false
```

(`CodingKeys` is synthesized from properties in this file — no explicit enum exists, so nothing else to update.)

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: PASS (all `RecordingModelTests`).

- [ ] **Step 5: Commit**

```bash
git add SynapseMeetings/Models/Recording.swift SynapseMeetingsTests/RecordingModelTests.swift
git commit -m "feat: add Recording.hasSystemAudio flag with decode back-compat"
```

---

### Task 2: `CaptureContext` dual-track layout

**Files:**
- Modify: `SynapseMeetings/Services/AudioRecorder.swift` (the `CaptureContext` class + a new `CaptureLayout` enum)
- Test: `SynapseMeetingsTests/CaptureContextTests.swift`

**Interfaces:**
- Produces:
  - `enum CaptureLayout { case mono; case dualTrack(micChannels: Int) }`
  - `CaptureContext.init(audioFile:converter:targetFormat:layout:)` — `layout` defaults to `.mono` (existing call sites/tests unchanged).
  - In `.dualTrack` mode: input buffers with N channels are routed to stereo (channels `0..<micChannels` averaged → L, the rest averaged → R) **before** conversion/write; `drainSamples()`/`snapshotSamples()` return the **mono mix** `(L+R)/2`; RMS level comes from channel 0 (mic) as today.
- Consumed by: Task 4 (`AudioRecorder.start` passes `.dualTrack`; `fireChunk` relies on mono drain).

- [ ] **Step 1: Write the failing tests**

Append to `SynapseMeetingsTests/CaptureContextTests.swift`. First add this helper next to `makeSineBuffer`:

```swift
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

private func makeStereoTargetFormat() -> AVAudioFormat {
    AVAudioFormat(commonFormat: .pcmFormatFloat32,
                  sampleRate: 16_000,
                  channels: 2,
                  interleaved: false)!
}
```

Then the tests:

```swift
    // MARK: Dual-track layout

    /// 3-channel input (1 mic + 2 tap), constant values: mic=0.5, tapL=0.2, tapR=0.4.
    /// Expect file channel L = 0.5 (mic), R = 0.3 (tap average).
    func testDualTrack_routesMicToLeftAndSystemToRight() throws {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 16_000,
                                        channels: 3,
                                        interleaved: false)!
        let target = makeStereoTargetFormat()
        let url = makeTempURL()
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }

        let file = try makeAudioFile(at: url, format: target)
        // nil converter: routed stereo is already at the target rate/format.
        let ctx = CaptureContext(audioFile: file, converter: nil, targetFormat: target,
                                 layout: .dualTrack(micChannels: 1))

        let buf = makeConstantBuffer(format: inputFormat, frameCount: 1600,
                                     values: [0.5, 0.2, 0.4])
        let result = ctx.ingest(buffer: buf)
        XCTAssertNil(result.error)
        ctx.finish()

        let readBack = try AVAudioFile(forReading: url)
        XCTAssertEqual(readBack.processingFormat.channelCount, 2)
        let readBuf = AVAudioPCMBuffer(pcmFormat: readBack.processingFormat,
                                       frameCapacity: 1600)!
        try readBack.read(into: readBuf)
        XCTAssertEqual(Int(readBuf.frameLength), 1600)
        XCTAssertEqual(readBuf.floatChannelData![0][0], 0.5, accuracy: 0.001, "L must be the mic channel")
        XCTAssertEqual(readBuf.floatChannelData![1][0], 0.3, accuracy: 0.001, "R must be the averaged tap channels")
    }

    /// drainSamples in dual-track mode returns the mono mix (L+R)/2 = (0.5+0.3)/2 = 0.4.
    func testDualTrack_drainReturnsMonoMix() throws {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 16_000,
                                        channels: 3,
                                        interleaved: false)!
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
        XCTAssertEqual(drained.count, 800, "drain must return one mono sample per frame")
        XCTAssertEqual(drained[0], 0.4, accuracy: 0.001, "drain must be the (L+R)/2 mono mix")
        ctx.finish()
    }

    /// Level (RMS) in dual-track mode reflects the mic (L) channel only:
    /// mic silent + loud tap ⇒ RMS 0.
    func testDualTrack_levelReflectsMicChannelOnly() throws {
        let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                        sampleRate: 16_000,
                                        channels: 3,
                                        interleaved: false)!
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project SynapseMeetings.xcodeproj -scheme SynapseMeetings \
  -destination 'platform=macOS' -only-testing:SynapseMeetingsTests/CaptureContextTests
```
Expected: **compile error** — `CaptureContext` init has no `layout` parameter / `CaptureLayout` not defined.

- [ ] **Step 3: Implement**

In `SynapseMeetings/Services/AudioRecorder.swift`:

1. Above `CaptureContext`, add:

```swift
/// How CaptureContext interprets incoming buffer channels.
enum CaptureLayout {
    /// Everything downmixed to one channel (existing behavior).
    case mono
    /// Dual-track: input channels 0..<micChannels average → L ("You"),
    /// remaining channels (the system-audio tap) average → R ("Them").
    case dualTrack(micChannels: Int)
}
```

2. `CaptureContext` gains a `let layout: CaptureLayout` member; the init takes `layout: CaptureLayout = .mono` and stores it.

3. At the top of `ingest(buffer:)`, immediately after the `guard !finished` line, route the buffer:

```swift
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
```

(Rename the incoming parameter to `rawBuffer`: `func ingest(buffer rawBuffer: AVAudioPCMBuffer)` — the external call sites keep the `buffer:` label.) The rest of `ingest` (converter/passthrough, write, append, RMS) operates on the routed `buffer` unchanged.

4. Add the routing helper inside `CaptureContext`:

```swift
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
```

5. Update `appendSamples(from:)` to mix stereo output buffers down to mono for the live-chunk buffer:

```swift
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
            pcmBuffer.append(contentsOf: Array(UnsafeBufferPointer(start: channelData[0], count: frames)))
        }
    }
```

6. `computeRMS(from:)` needs no change — it already reads `floatChannelData?[0]`, which is the mic channel in both layouts.

- [ ] **Step 4: Run tests to verify they pass**

Same command as Step 2. Expected: PASS — all `CaptureContextTests` including the four pre-existing ones (`.mono` default keeps them green).

- [ ] **Step 5: Commit**

```bash
git add SynapseMeetings/Services/AudioRecorder.swift SynapseMeetingsTests/CaptureContextTests.swift
git commit -m "feat: dual-track CaptureLayout in CaptureContext (mic->L, system->R, mono drain)"
```

---

### Task 3: `SystemAudioTap` service + Info.plist permission string

**Files:**
- Create: `SynapseMeetings/Services/SystemAudioTap.swift`
- Modify: `project.yml` (Info.plist properties)
- Test: none (thin OS-API glue, exercised manually in Task 9; failure paths covered by Task 4's fallback)

**Interfaces:**
- Produces (all `@available(macOS 14.4, *)`):
  - `SystemAudioTap.activate(preferredMicUID: String) throws -> ActivationResult` where `ActivationResult` has `aggregateID: AudioDeviceID` and `micChannelCount: Int`.
  - `SystemAudioTap.teardown()` — idempotent, destroys aggregate then tap.
- Consumes: `AudioDeviceService.enumerateInputDevices()` (currently `private static` — this task makes it `static`).

- [ ] **Step 1: Expose device enumeration**

In `SynapseMeetings/Services/AudioDeviceService.swift`, change:

```swift
    private static func enumerateInputDevices() -> [InputDevice] {
```
to
```swift
    static func enumerateInputDevices() -> [InputDevice] {
```

- [ ] **Step 2: Create `SystemAudioTap.swift`**

```swift
import Foundation
import CoreAudio
import AudioToolbox

/// Wraps a Core Audio process tap (global system-output mixdown, excluding our
/// own process) plus an aggregate device combining that tap with the microphone.
/// Both sources share the aggregate's clock (tap drift-compensated), so
/// AVAudioEngine receives mic + system channels sample-aligned: the mic's
/// channels come first (it is the only sub-device), the tap's stereo mixdown after.
///
/// The first activation triggers macOS's "record system audio" consent prompt
/// (NSAudioCaptureUsageDescription). If the user denies it, tap creation fails
/// or the tap delivers silence — the caller falls back to mic-only either way.
@available(macOS 14.4, *)
final class SystemAudioTap {
    struct ActivationResult {
        let aggregateID: AudioDeviceID
        let micChannelCount: Int
    }

    enum TapError: LocalizedError {
        case noMicrophone
        case osStatus(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .noMicrophone:
                return "No input device available for the capture aggregate"
            case .osStatus(let what, let status):
                return "\(what) failed (OSStatus \(status))"
            }
        }
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioDeviceID(kAudioObjectUnknown)

    deinit { teardown() }

    /// Builds tap + aggregate. On any failure, cleans up whatever was created
    /// and throws — the caller records mic-only.
    func activate(preferredMicUID: String) throws -> ActivationResult {
        guard let mic = Self.resolveMic(preferredUID: preferredMicUID) else {
            throw TapError.noMicrophone
        }

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
        tapDescription.name = "Synapse Meetings System Tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw TapError.osStatus("AudioHardwareCreateProcessTap", tapStatus)
        }
        tapID = newTapID

        // Mic is the sole sub-device → its channels occupy indices 0..<micChannelCount.
        // The tap is drift-compensated against the mic's clock.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Synapse Meetings Capture",
            kAudioAggregateDeviceUIDKey: "com.synapsemeetings.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: mic.uid]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var newAggregateID = AudioDeviceID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard aggStatus == noErr, newAggregateID != kAudioObjectUnknown else {
            teardown()
            throw TapError.osStatus("AudioHardwareCreateAggregateDevice", aggStatus)
        }
        aggregateID = newAggregateID

        return ActivationResult(
            aggregateID: aggregateID,
            micChannelCount: max(1, Int(mic.inputChannelCount))
        )
    }

    func teardown() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioDeviceID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Helpers

    /// Preferred mic if currently connected, else the system default input.
    private static func resolveMic(preferredUID: String) -> InputDevice? {
        let devices = AudioDeviceService.enumerateInputDevices()
        let trimmed = preferredUID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let preferred = devices.first(where: { $0.uid == trimmed }) {
            return preferred
        }
        guard let defaultID = defaultInputDeviceID() else { return devices.first }
        return devices.first(where: { $0.id == defaultID }) ?? devices.first
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Our own process as an AudioObject, so Synapse's sounds are excluded
    /// from the tap. Empty array (capture everything) if translation fails.
    private static func ownProcessObjects() -> [AudioObjectID] {
        var pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPtr,
                &size,
                &objectID
            )
        }
        guard status == noErr, objectID != kAudioObjectUnknown else { return [] }
        return [objectID]
    }
}
```

- [ ] **Step 3: Add the permission string to `project.yml`**

In `targets.SynapseMeetings.info.properties`, after `NSMicrophoneUsageDescription`:

```yaml
        NSAudioCaptureUsageDescription: "Synapse Meetings records system audio during meetings so both sides of a headphone call appear in your transcript."
```

- [ ] **Step 4: Regenerate and build**

```bash
xcodegen generate
xcodebuild build -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS'
```
Expected: **BUILD SUCCEEDED**. Then verify the plist key landed:

```bash
grep -A1 NSAudioCaptureUsageDescription SynapseMeetings/Info.plist
```
Expected: the usage string above.

- [ ] **Step 5: Commit**

```bash
git add SynapseMeetings/Services/SystemAudioTap.swift SynapseMeetings/Services/AudioDeviceService.swift project.yml SynapseMeetings/Info.plist
git commit -m "feat: SystemAudioTap — process tap + mic aggregate device (macOS 14.4+)"
```

(If `SynapseMeetings/Info.plist` is gitignored/generated, commit without it.)

---

### Task 4: `AudioRecorder` integration — record stereo via the aggregate

**Files:**
- Modify: `SynapseMeetings/Services/AudioRecorder.swift` (the `AudioRecorder` class)
- Test: existing `CaptureContextTests` stay green; recorder wiring is compile-verified + manually verified in Task 9 (it drives live audio hardware)

**Interfaces:**
- Consumes: `SystemAudioTap.activate(preferredMicUID:)` / `.teardown()` (Task 3), `CaptureLayout.dualTrack` (Task 2).
- Produces (used by Tasks 7–8):
  - `AudioRecorder.systemAudioEnabled: Bool` (set by AppState before `start`)
  - `@Published private(set) var systemAudioActive: Bool` — true while the current recording is dual-track
  - `@Published private(set) var systemAudioNotice: String?` — non-blocking fallback message

- [ ] **Step 1: Add state**

In `AudioRecorder`, next to `preferredInputDeviceUID`:

```swift
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
```

- [ ] **Step 2: Refactor device override into a reusable helper**

Replace the body of `applyPreferredInputDevice()` so device-setting is callable with any ID:

```swift
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
```

- [ ] **Step 3: Wire the tap into `start(writingTo:)`**

In `start(writingTo:)`, replace the single `applyPreferredInputDevice()` call with tap activation + fallback (this must run **before** `input.outputFormat(forBus: 0)` is read, in the same position `applyPreferredInputDevice()` occupies today):

```swift
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
```

- [ ] **Step 4: Make the target format follow the layout**

Still in `start(writingTo:)`:

1. The target format's channel count becomes layout-dependent — replace `channels: targetChannels` with:

```swift
        let outputChannels: AVAudioChannelCount = systemAudioActive ? 2 : targetChannels
```
and use `channels: outputChannels` in the `AVAudioFormat` call, `AVNumberOfChannelsKey: outputChannels` in `fileSettings`.

2. The converter's **input** format must match what `CaptureContext` feeds it. In `.dualTrack`, routing happens first, so the converter sees stereo at the input sample rate. Replace `let converter = AVAudioConverter(from: inputFormat, to: targetFormat)` with:

```swift
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
```

3. Pass the layout to the context:

```swift
        let context = CaptureContext(audioFile: file, converter: converter,
                                     targetFormat: targetFormat, layout: layout)
```

- [ ] **Step 5: Mono chunk export**

`fireChunk()` currently uses `context.targetFormat` (now possibly stereo) for the chunk file, but `drainSamples()` returns mono. Derive a mono format:

```swift
        guard let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                             sampleRate: format.sampleRate,
                                             channels: 1,
                                             interleaved: false) else { return }
```
(right after `let format = context.targetFormat`), then use `monoFormat` everywhere `format` is used below it: `AVSampleRateKey: monoFormat.sampleRate`, `AVNumberOfChannelsKey: 1`, and `AVAudioPCMBuffer(pcmFormat: monoFormat, ...)`.

- [ ] **Step 6: Teardown in `stop()`**

After `captureContext = nil` in `stop()`:

```swift
        if #available(macOS 14.4, *), let tap = systemTap as? SystemAudioTap {
            tap.teardown()
        }
        systemTap = nil
        systemAudioActive = false
```

- [ ] **Step 7: Build and run the full test suite**

```bash
xcodebuild test -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS'
```
Expected: **BUILD SUCCEEDED**, all existing tests PASS (mic-only path is byte-for-byte the old behavior: `.mono` layout, `targetChannels` = 1, converter from `inputFormat`).

- [ ] **Step 8: Commit**

```bash
git add SynapseMeetings/Services/AudioRecorder.swift
git commit -m "feat: AudioRecorder records dual-track via system-tap aggregate with mic-only fallback"
```

---

### Task 5: Channel envelopes + token attribution

**Files:**
- Create: `SynapseMeetings/Services/ChannelAttribution.swift`
- Modify: `SynapseMeetings/Models/AppState.swift` (extract shared turn-builder; add `attributeTokensToChannels`)
- Test: create `SynapseMeetingsTests/ChannelAttributionTests.swift`

**Interfaces:**
- Produces:
  - `enum AudioSource { case mic, system }`
  - `struct ChannelEnvelopes` with `left: [Float]`, `right: [Float]`, `windowDuration: Double`, `var isStereo: Bool`, `func source(start: Double, end: Double) -> AudioSource`, `static func load(from url: URL, windowDuration: Double = 0.05) throws -> ChannelEnvelopes`, `static func writeSystemChannel(from url: URL) throws -> URL`
  - `AppState.attributeTokensToChannels(tokens: [TokenTiming], envelopes: ChannelEnvelopes, systemSegments: [TimedSpeakerSegment]?) -> [SpeakerTurn]` (static)
- Consumes: `TokenTiming` / `TimedSpeakerSegment` / `SpeakerTurn` (FluidAudio + existing model), the run-joining/SentencePiece logic currently inside `alignTokensToSpeakers`.
- Consumed by: Task 6 (pipeline).

- [ ] **Step 1: Write the failing tests**

Create `SynapseMeetingsTests/ChannelAttributionTests.swift`:

```swift
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
```

- [ ] **Step 2: Run tests to verify they fail**

```bash
xcodebuild test -project SynapseMeetings.xcodeproj -scheme SynapseMeetings \
  -destination 'platform=macOS' -only-testing:SynapseMeetingsTests/ChannelAttributionTests
```
Expected: **compile error** — `ChannelEnvelopes` / `attributeTokensToChannels` not defined.

(New test file requires `xcodegen generate` first so it joins the test target:)
```bash
xcodegen generate
```

- [ ] **Step 3: Implement `ChannelAttribution.swift`**

```swift
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
```

- [ ] **Step 4: Extract the shared turn-builder in `AppState` and add `attributeTokensToChannels`**

In `SynapseMeetings/Models/AppState.swift`, inside the `// MARK: - Diarization alignment` section:

1. Add the shared builder (the flush/run-joining logic currently inlined in `alignTokensToSpeakers`):

```swift
    /// Shared turn-builder: walks tokens, asks `labelFor` for each token's speaker
    /// label, joins consecutive same-label tokens into runs, and reassembles
    /// SentencePiece pieces (▁ = word boundary) into text.
    private static func buildTurns(
        tokens: [TokenTiming],
        labelFor: (TokenTiming) -> String
    ) -> [SpeakerTurn] {
        var turns: [SpeakerTurn] = []
        var currentLabel: String? = nil
        var currentStart: Double = 0
        var currentEnd: Double = 0
        var currentPieces: [String] = []

        func flushCurrent() {
            guard let label = currentLabel else { return }
            let text = decodePieces(currentPieces)
            if !text.isEmpty {
                turns.append(SpeakerTurn(
                    speakerLabel: label,
                    startSec: currentStart,
                    endSec: currentEnd,
                    text: text
                ))
            }
            currentLabel = nil
            currentPieces.removeAll(keepingCapacity: true)
        }

        for token in tokens {
            let label = labelFor(token)
            if label == currentLabel {
                currentPieces.append(token.token)
                currentEnd = token.endTime
            } else {
                flushCurrent()
                currentLabel = label
                currentStart = token.startTime
                currentEnd = token.endTime
                currentPieces = [token.token]
            }
        }
        flushCurrent()
        return turns
    }
```

2. Rewrite `alignTokensToSpeakers` as a thin wrapper (behavior identical — existing `AppStatePipelineTests` must stay green):

```swift
    static func alignTokensToSpeakers(
        tokens: [TokenTiming],
        segments: [TimedSpeakerSegment]
    ) -> [SpeakerTurn] {
        guard !tokens.isEmpty, !segments.isEmpty else { return [] }

        var labelMap: [String: String] = [:]
        var nextSpeakerNumber = 1
        func labelFor(_ rawId: String) -> String {
            if let existing = labelMap[rawId] { return existing }
            let label = "Speaker \(nextSpeakerNumber)"
            nextSpeakerNumber += 1
            labelMap[rawId] = label
            return label
        }

        let sortedSegments = segments.sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var segIdx = 0

        return buildTurns(tokens: tokens) { token in
            let mid = (token.startTime + token.endTime) / 2
            while segIdx + 1 < sortedSegments.count,
                  Double(sortedSegments[segIdx + 1].startTimeSeconds) <= mid {
                segIdx += 1
            }
            return labelFor(sortedSegments[segIdx].speakerId)
        }
    }
```

3. Add the channel-attribution entry point below it:

```swift
    /// Dual-track attribution: mic-energy tokens are "You"; system-energy tokens
    /// are "Them", or — when the system channel was diarized — "Speaker N" with
    /// stable first-appearance numbering.
    static func attributeTokensToChannels(
        tokens: [TokenTiming],
        envelopes: ChannelEnvelopes,
        systemSegments: [TimedSpeakerSegment]?
    ) -> [SpeakerTurn] {
        guard !tokens.isEmpty else { return [] }

        var labelMap: [String: String] = [:]
        var nextSpeakerNumber = 1
        let sortedSegments = (systemSegments ?? []).sorted { $0.startTimeSeconds < $1.startTimeSeconds }
        var segIdx = 0

        return buildTurns(tokens: tokens) { token in
            switch envelopes.source(start: token.startTime, end: token.endTime) {
            case .mic:
                return "You"
            case .system:
                guard !sortedSegments.isEmpty else { return "Them" }
                let mid = (token.startTime + token.endTime) / 2
                while segIdx + 1 < sortedSegments.count,
                      Double(sortedSegments[segIdx + 1].startTimeSeconds) <= mid {
                    segIdx += 1
                }
                let rawId = sortedSegments[segIdx].speakerId
                if let existing = labelMap[rawId] { return existing }
                let label = "Speaker \(nextSpeakerNumber)"
                nextSpeakerNumber += 1
                labelMap[rawId] = label
                return label
            }
        }
    }
```

- [ ] **Step 5: Run the new tests and the alignment regression tests**

```bash
xcodebuild test -project SynapseMeetings.xcodeproj -scheme SynapseMeetings \
  -destination 'platform=macOS' \
  -only-testing:SynapseMeetingsTests/ChannelAttributionTests \
  -only-testing:SynapseMeetingsTests/AppStatePipelineTests
```
Expected: PASS — including all pre-existing `alignTokensToSpeakers` tests (refactor must not change behavior).

- [ ] **Step 6: Commit**

```bash
git add SynapseMeetings/Services/ChannelAttribution.swift SynapseMeetings/Models/AppState.swift SynapseMeetingsTests/ChannelAttributionTests.swift
git commit -m "feat: channel envelopes + You/Them token attribution with shared turn-builder"
```

---

### Task 6: Pipeline wiring — dual-track branch in `executePipeline`

**Files:**
- Modify: `SynapseMeetings/Models/AppState.swift` (`executePipeline`)
- Test: `SynapseMeetingsTests/PipelineExecutionTests.swift`

**Interfaces:**
- Consumes: `Recording.hasSystemAudio` (Task 1), `ChannelEnvelopes.load/.writeSystemChannel` (Task 5), `attributeTokensToChannels` (Task 5).
- Produces: `speakerTurns` labeled `You`/`Them`/`Speaker N` on dual-track recordings; these flow into `formatSpeakerTurns` → summarizer prompt via the existing code path.

- [ ] **Step 1: Write the failing test (labels flow to the summarizer)**

The transcription step needs real ASR models, so the pipeline test exercises the downstream half: pre-set `speakerTurns` with `You`/`Them` labels (as the new branch produces) and assert the summarizer receives the labeled transcript. Append to `PipelineExecutionTests`:

```swift
    private final class CapturingSummarizer: Summarizing, @unchecked Sendable {
        private(set) var receivedTranscript: String = ""
        private(set) var receivedSpeakerLabeled: Bool = false
        func summarize(
            transcript: String,
            liveNotes: String,
            attendees: [String],
            speakerLabeled: Bool,
            suggestedTitle: String?,
            systemPromptOverride: String?,
            userPromptTemplateOverride: String?
        ) async throws -> String {
            receivedTranscript = transcript
            receivedSpeakerLabeled = speakerLabeled
            return "# Done\n\nSummary"
        }
    }

    /// Dual-track recordings feed the summarizer a You/Them-labeled transcript
    /// through the existing speakerTurns path.
    func testDualTrackSpeakerTurns_flowToSummarizer() async throws {
        let summarizer = CapturingSummarizer()
        let app = AppState(
            store: RecordingStore(baseDirectory: tempDir),
            makeSummarizer: { _ in summarizer }
        )
        var rec = Recording(audioFilename: "test.wav", hasSystemAudio: true)
        rec.transcript = "Hi there Hello back"
        rec.speakerTurns = [
            SpeakerTurn(speakerLabel: "You", startSec: 0, endSec: 1, text: "Hi there"),
            SpeakerTurn(speakerLabel: "Them", startSec: 1, endSec: 2, text: "Hello back")
        ]
        rec.status = .summarizing
        app.store.upsert(rec)

        await app.executePipeline(id: rec.id)

        XCTAssertTrue(summarizer.receivedSpeakerLabeled)
        XCTAssertEqual(summarizer.receivedTranscript, "You: Hi there\n\nThem: Hello back")
        let result = app.store.recordings.first(where: { $0.id == rec.id })
        XCTAssertEqual(result?.status, .ready)
        XCTAssertTrue(result?.summaryMarkdown.contains("You: Hi there") == true,
                      "Raw transcript section must carry the You/Them labels")
    }
```

- [ ] **Step 2: Run test to verify it fails**

```bash
xcodebuild test -project SynapseMeetings.xcodeproj -scheme SynapseMeetings \
  -destination 'platform=macOS' -only-testing:SynapseMeetingsTests/PipelineExecutionTests
```
Expected: **compile error** — `Recording` init call is fine (Task 1 added the param), so if Task 1 landed this test may already PASS (the plumbing exists). If it passes, treat this step as a characterization test and continue — the new pipeline branch (Step 3) is still required for real recordings, where `speakerTurns` don't pre-exist.

- [ ] **Step 3: Implement the dual-track transcription branch**

In `executePipeline(id:forceSummarize:)`, replace the transcription block — everything from `let runDiarization = diarizationEnabled` through the end of the `else` branch (`if updated == nil { return }`) — with:

```swift
                let runDiarization = diarizationEnabled

                // Dual-track: attribute tokens to channels (You vs Them).
                // Envelope load streams the file; run it off the main actor.
                var envelopes: ChannelEnvelopes? = nil
                if snap.hasSystemAudio {
                    envelopes = try? await Task.detached {
                        try ChannelEnvelopes.load(from: audioURL)
                    }.value
                    if envelopes?.isStereo != true { envelopes = nil } // mono despite flag → normal path
                }

                if let envelopes {
                    async let asrTask = transcriber.transcribeWithTimings(fileAt: audioURL)
                    // Diarize only the system channel so remote speakers cluster
                    // cleanly and the user's voice never lands in the clusters.
                    var systemSegments: [TimedSpeakerSegment]? = nil
                    if runDiarization,
                       let systemURL = try? await Task.detached(operation: {
                           try ChannelEnvelopes.writeSystemChannel(from: audioURL)
                       }).value {
                        systemSegments = try? await diarizer.diarize(fileAt: systemURL, numSpeakers: -1)
                        try? FileManager.default.removeItem(at: systemURL)
                    }
                    let asrResult = try await asrTask
                    let segments = systemSegments

                    let updated = applyPipelineUpdate(id: id) {
                        $0.transcript = asrResult.text
                        if let timings = asrResult.tokenTimings, !timings.isEmpty {
                            $0.speakerTurns = Self.attributeTokensToChannels(
                                tokens: timings,
                                envelopes: envelopes,
                                systemSegments: segments
                            )
                        }
                    }
                    if updated == nil { return }
                } else if runDiarization {
                    // Speaker count hint: number of currently-checked attendees, if any.
                    // Use the snap from before the await so the hint is consistent.
                    let hintedSpeakerCount = snap.attendees.filter { $0.selected }.count
                    async let asrTask = transcriber.transcribeWithTimings(fileAt: audioURL)
                    async let diarizeTask: [TimedSpeakerSegment]? = (try? await diarizer.diarize(
                        fileAt: audioURL,
                        numSpeakers: hintedSpeakerCount > 1 ? hintedSpeakerCount : -1
                    ))
                    let asrResult = try await asrTask
                    let segments = await diarizeTask

                    let updated = applyPipelineUpdate(id: id) {
                        $0.transcript = asrResult.text
                        if let segments, let timings = asrResult.tokenTimings, !timings.isEmpty {
                            $0.speakerTurns = Self.alignTokensToSpeakers(
                                tokens: timings,
                                segments: segments
                            )
                        }
                    }
                    if updated == nil { return }
                } else {
                    let transcript = try await transcriber.transcribe(fileAt: audioURL)
                    let updated = applyPipelineUpdate(id: id) { $0.transcript = transcript }
                    if updated == nil { return }
                }
```

(The `runDiarization`-branch and `else`-branch bodies are today's code, unchanged; only the `if let envelopes` branch is new.)

- [ ] **Step 4: Run the full pipeline test classes**

```bash
xcodebuild test -project SynapseMeetings.xcodeproj -scheme SynapseMeetings \
  -destination 'platform=macOS' \
  -only-testing:SynapseMeetingsTests/PipelineExecutionTests \
  -only-testing:SynapseMeetingsTests/AppStatePipelineTests
```
Expected: PASS (new test + all regressions).

- [ ] **Step 5: Commit**

```bash
git add SynapseMeetings/Models/AppState.swift SynapseMeetingsTests/PipelineExecutionTests.swift
git commit -m "feat: dual-track pipeline branch — channel attribution + system-channel diarization"
```

---

### Task 7: Recording start wiring + settings storage

**Files:**
- Modify: `SynapseMeetings/Models/AppState.swift` (`@AppStorage` + `startNewRecording`)
- Test: `SynapseMeetingsTests/AppStatePipelineTests.swift` (compile-level; behavior is recorder-driven and covered manually) — no new test needed; existing suites must stay green

**Interfaces:**
- Consumes: `AudioRecorder.systemAudioEnabled` / `.systemAudioActive` (Task 4), `Recording.hasSystemAudio` (Task 1).
- Produces: `AppState.systemAudioCaptureEnabled` (`@AppStorage`, default `true`) — consumed by Task 8's UI.

- [ ] **Step 1: Add the setting**

In `AppState`, next to `@AppStorage("diarizationEnabled")`:

```swift
    @AppStorage("systemAudioCaptureEnabled") var systemAudioCaptureEnabled: Bool = true
```

- [ ] **Step 2: Wire it into `startNewRecording()`**

In `startNewRecording()`, after `recorder.preferredInputDeviceUID = audioInputDeviceUID`:

```swift
        recorder.systemAudioEnabled = systemAudioCaptureEnabled
```

and after `try recorder.start(writingTo: url)` — when building the `Recording` — record what actually happened (activation can fail and fall back):

```swift
        var recording = Recording(
            title: resolvedTitle,
            audioFilename: url.lastPathComponent,
            status: .recording,
            attendees: prefill?.attendees ?? [],
            hasSystemAudio: recorder.systemAudioActive
        )
```

(`hasSystemAudio:` goes after `attendees:` — Task 1 placed the init parameter after `speakerTurns:`, and Swift default-parameter call sites may skip `speakerTurns`.)

- [ ] **Step 3: Build + full test suite**

```bash
xcodebuild test -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDED, all tests PASS.

- [ ] **Step 4: Commit**

```bash
git add SynapseMeetings/Models/AppState.swift
git commit -m "feat: systemAudioCaptureEnabled setting wired into recording start"
```

---

### Task 8: Settings UI + recording-banner notice

**Files:**
- Modify: `SynapseMeetings/Views/SettingsView.swift` (`audioTab`)
- Modify: `SynapseMeetings/Views/RecordingDetailView.swift` (recording top bar, ~line 214)
- Test: none (SwiftUI declarative view code; verified by build + Task 9 manual pass)

**Interfaces:**
- Consumes: `app.systemAudioCaptureEnabled` (Task 7), `app.recorder.systemAudioNotice` (Task 4).

- [ ] **Step 1: Add the System audio section to `audioTab`**

In `SettingsView.swift`, inside `audioTab`'s `Form`, insert between the `Section("Recording input")` and `Section("Speaker diarization")`:

```swift
            Section("System audio") {
                if #available(macOS 14.4, *) {
                    Toggle("Capture system audio (both sides of headphone calls)",
                           isOn: $app.systemAudioCaptureEnabled)
                    Text("Records what you hear — Zoom, Meet, Teams — alongside your microphone, and labels the transcript You / Them. macOS asks for System Audio Recording permission on first use.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Toggle("Capture system audio (both sides of headphone calls)",
                           isOn: .constant(false))
                        .disabled(true)
                    Text("Requires macOS 14.4 or later. Recordings capture only your microphone on this system.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
```

- [ ] **Step 2: Update the stale virtual-mixer caption**

In the same file, replace:

```swift
                Text("Pick a virtual mixer (e.g. BlackHole, Loopback) to capture meeting audio + your mic together.")
```
with:
```swift
                Text("Your microphone. With system audio capture on, the other side of the call is recorded automatically — no virtual mixer needed.")
```

- [ ] **Step 3: Show the fallback notice in the recording banner**

In `RecordingDetailView.swift`, in the recording top bar `HStack` (after the `Text(formattedElapsed(app.recorder.elapsed))` line and before `Spacer()`), add:

```swift
                if let notice = app.recorder.systemAudioNotice {
                    Label(notice, systemImage: "speaker.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
```

- [ ] **Step 4: Build**

```bash
xcodebuild build -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS'
```
Expected: BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add SynapseMeetings/Views/SettingsView.swift SynapseMeetings/Views/RecordingDetailView.swift
git commit -m "feat: system audio capture toggle + fallback notice UI"
```

---

### Task 9: Prompt tweak + full suite + manual verification

**Files:**
- Modify: `SynapseMeetings/Services/SummarizationPrompts.swift` (speaker-block wording)
- Test: full suite + manual end-to-end

- [ ] **Step 1: Teach the prompt about You/Them labels**

In `SummarizationPrompts.swift`, the `speakerBlock` string currently describes only `Speaker 1:` / `Speaker 2:` labels. Replace its first sentence:

```
The transcript below has been diarized — each block is prefixed with `Speaker 1:`, `Speaker 2:`, etc., where the same number always refers to the same physical speaker.
```
with:
```
The transcript below is speaker-labeled. `You:` marks the user who recorded the meeting (attribute their remarks and action items to the user by name if attendees identify them). `Them:` or `Speaker 1:`, `Speaker 2:`, etc. mark the other participants, where the same number always refers to the same physical speaker.
```
(The rest of the block — the quote/action-item mapping guidance — stays as is.)

- [ ] **Step 2: Run the entire test suite**

```bash
xcodebuild test -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS'
```
Expected: all tests PASS (AnthropicPromptTests cover prompt rendering — update any assertion that pins the old sentence verbatim).

- [ ] **Step 3: Commit**

```bash
git add SynapseMeetings/Services/SummarizationPrompts.swift SynapseMeetingsTests/AnthropicPromptTests.swift
git commit -m "feat: summarization prompt understands You/Them speaker labels"
```

- [ ] **Step 4: Manual verification (requires a human + Developer ID build)**

Ad-hoc-signed dev builds get TCC prompts silently denied (repo gotcha), so the permission flow needs a signed build — follow `.agents/commands/EXPORT-SIGNED-APP.md` or test with the fallback path in dev. Checklist to hand to the user:

1. Launch the app, start a recording, play any audio (YouTube/Zoom test call) **with headphones on**.
2. First run: macOS shows the "Synapse Meetings wants to record system audio" prompt → Allow.
3. Speak + let the remote/system side play; stop the recording.
4. Verify: live transcript included the system-audio side; final transcript has `You:` / `Them:` (or `Speaker N`) labels; `~/Library/Application Support/Synapse Meetings/audio/<id>.wav` is stereo (`afinfo <file>` shows 2 ch).
5. Toggle **Settings → Audio → Capture system audio** off → new recording is mono, no notice.
6. On the ad-hoc dev build (permission auto-denied): recording still works, banner shows "System audio unavailable — recorded microphone only", file is mono, `hasSystemAudio` stays false. **Also confirms FluidAudio ASR accepts the stereo WAV** (if step 4's transcription failed on stereo input, add a downmix-to-temp-mono step before ASR in the dual-track branch — `ChannelEnvelopes`-style streaming average of L/R — and re-run).

- [ ] **Step 5: Final commit / branch integration**

Use the superpowers:finishing-a-development-branch skill (merge vs PR per repo conventions — `.agents/commands/OPEN-PR.md`).
