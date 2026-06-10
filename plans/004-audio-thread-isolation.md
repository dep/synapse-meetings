# Plan 004: Make the audio tap path thread-safe (stop calling MainActor code on the render thread)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat c234ef6..HEAD -- SynapseMeetings/Services/AudioRecorder.swift`
> If the file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (touches the live capture path — a bug here corrupts recordings)
- **Depends on**: plans/003-pipeline-test-seam-and-ci.md (CI safety net) — recommended, not strictly required
- **Category**: bug
- **Planned at**: commit `c234ef6`, 2026-06-10

## Why this matters

`AudioRecorder` is `@MainActor`, but the `AVAudioEngine` input tap invokes
`handleTap` **synchronously on the realtime audio render thread**. This compiles in
Swift 5.10 only because `AVAudioNodeTapBlock` predates `Sendable` checking — the
isolation is silently violated. Concretely: the render thread reads `audioFile`,
`converter`, and `targetFormat` while the main thread's `stop()` sets them to nil;
`AVAudioFile.write` can race the teardown. This is undefined behavior that
manifests as rare crashes or truncated recordings at stop, and it hard-blocks any
future Swift 6 / strict-concurrency migration. The fix moves all tap-side state
into a dedicated, lock-protected capture context that the tap closure owns, with
no `self` property access from the render thread.

## Current state

One relevant file: `SynapseMeetings/Services/AudioRecorder.swift` (306 lines) —
`@MainActor final class AudioRecorder: ObservableObject`.

The violation — tap installation at `AudioRecorder.swift:107-109`:

```swift
input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
    self?.handleTap(buffer: buffer, targetFormat: targetFormat)
}
```

`handleTap` (lines 188-224) is MainActor-isolated but runs on the render thread; it
reads `self.converter` and `self.audioFile` and then writes/levels:

```swift
private func handleTap(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
    guard let converter, let audioFile else { return }
    // ... AVAudioConverter conversion ...
    if outputBuffer.frameLength > 0 {
        do {
            try audioFile.write(from: outputBuffer)
        } catch {
            Task { @MainActor in self.lastError = error.localizedDescription }
        }
        appendToPCMBuffer(outputBuffer)   // pcmBufferQueue.sync { ... } — already serialized
        updateLevel(from: outputBuffer)   // Task { @MainActor in self.level = ... } — already safe
    }
}
```

The teardown race — `stop()` (lines 130-147) on the main thread:

```swift
@discardableResult
func stop() -> URL? {
    guard isRecording else { return outputURL }
    chunkTimer?.invalidate()
    chunkTimer = nil
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    engine.reset()
    timer?.invalidate()
    timer = nil
    isRecording = false
    audioFile = nil          // ← races an in-flight handleTap on the render thread
    targetFormat = nil
    pcmBufferQueue.sync { pcmBuffer.removeAll(keepingCapacity: false) }
    let url = outputURL
    outputURL = nil
    return url
}
```

Mutable state currently touched from the tap path: `converter` (line 105),
`audioFile` (line 100), `pcmBuffer` + `pcmBufferQueue` (lines 28-29),
`level`/`lastError` (`@Published`, already updated via `Task { @MainActor }`).
State touched only on main: timers, `isRecording`, `elapsed`, `startedAt`,
`outputURL`, `targetFormat` (also read by `fireChunk`, line 150).

`fireChunk` (lines 149-186) runs on the main thread (Timer → `Task { @MainActor }`)
and reads `pcmBuffer` through `pcmBufferQueue.sync` — it will read from the new
context instead.

Repo conventions: no third-party concurrency utilities; use `NSLock` or a serial
`DispatchQueue` (the file already uses a serial queue). Plain XCTest for tests.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate project | `xcodegen generate` | exit 0 |
| Build | `xcodebuild -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS' build` | `BUILD SUCCEEDED` |
| Tests | `xcodebuild -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS' test` | `TEST SUCCEEDED` |
| Strict-concurrency spot check | add `-Xswiftc -strict-concurrency=targeted` is NOT wired into xcodebuild here — skip; rely on review | n/a |

## Scope

**In scope** (the only files you should modify/create):
- `SynapseMeetings/Services/AudioRecorder.swift`
- `SynapseMeetingsTests/CaptureContextTests.swift` (create)

**Out of scope** (do NOT touch):
- `SynapseMeetings/Models/AppState.swift` — the `onChunk` callback contract
  (called on main) must not change.
- `SynapseMeetings/Services/AudioDeviceService.swift` — device enumeration is fine.
- Chunking cadence / live-transcription strategy — that is plan 005. Do not change
  *what* `fireChunk` exports, only *where* it reads samples from.

## Git workflow

- Branch: `advisor/004-audio-thread-isolation`
- Commits: one for the context extraction, one for tests, e.g.
  `Isolate audio tap state into a lock-protected capture context`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Introduce a `CaptureContext` owned by the tap

In `AudioRecorder.swift`, add a final class that owns everything the render thread
touches, protected by a single lock:

```swift
/// Owns all state the AVAudioEngine tap touches. The tap closure holds the only
/// strong reference besides AudioRecorder. Every member is guarded by `lock` so
/// the render thread and main thread never race; `finish()` makes teardown safe
/// even if a tap callback is mid-flight.
final class CaptureContext: @unchecked Sendable {
    private let lock = NSLock()
    private var audioFile: AVAudioFile?
    private let converter: AVAudioConverter?
    let targetFormat: AVAudioFormat
    private var pcmBuffer: [Float] = []
    private var finished = false

    /// Called on the render thread with the raw input buffer.
    /// Returns an error message for the UI, or nil on success.
    func ingest(buffer: AVAudioPCMBuffer) -> (level: Float?, error: String?) { ... }

    /// Main thread: snapshot samples for chunk export.
    func snapshotSamples() -> [Float] { lock.withLock { pcmBuffer } }

    /// Main thread: stop accepting buffers and close the file.
    func finish() { lock.withLock { finished = true; audioFile = nil } }
}
```

`ingest` contains the body of today's `handleTap` (conversion, `audioFile.write`,
appending to `pcmBuffer`, RMS level computation), entirely under the lock, with an
early `guard !finished, audioFile != nil` return. It returns the computed level
and/or error string instead of touching `@Published` properties — the caller
decides how to publish.

Implementation notes:
- Move the conversion code (lines 191-213) and RMS code (lines 238-243) into
  `CaptureContext` verbatim where possible.
- `NSLock.withLock` exists on macOS 13+; deployment target is 14.0 — fine.
- Holding a lock on the render thread is the same cost profile as today's
  `pcmBufferQueue.sync`; do not introduce anything heavier (no DispatchQueue.async
  with buffer copies per tap callback).

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`

### Step 2: Rewire `AudioRecorder` to use the context

1. Replace the properties `audioFile`, `converter`, `pcmBuffer`, `pcmBufferQueue`,
   `targetFormat` with a single `private var captureContext: CaptureContext?`.
2. In `start(writingTo:)`: build the `AVAudioFile`, converter, and format as today,
   construct the context, then install the tap so it captures the **context
   directly, not `self`'s properties**:

```swift
let context = CaptureContext(audioFile: file, converter: converter, targetFormat: targetFormat)
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
```

3. In `stop()`: replace `audioFile = nil` / `targetFormat = nil` /
   `pcmBufferQueue.sync { ... }` with:

```swift
engine.inputNode.removeTap(onBus: 0)
engine.stop()
engine.reset()
captureContext?.finish()
captureContext = nil
```

   Ordering matters: removeTap/stop first (no new callbacks), then `finish()`
   (any in-flight callback exits via the `finished` guard or completes its write
   under the lock before the file closes).

4. In `fireChunk()`: read `guard let context = captureContext else { return }`,
   use `context.snapshotSamples()` and `context.targetFormat` in place of the old
   property reads. Everything else in `fireChunk` stays identical.

5. Delete `handleTap`, `appendToPCMBuffer`, `updateLevel` from `AudioRecorder`
   (their logic now lives in `CaptureContext`).

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`, and
`grep -n "pcmBufferQueue\|func handleTap\|func appendToPCMBuffer" SynapseMeetings/Services/AudioRecorder.swift` → no matches.

### Step 3: Tests for the context

Create `SynapseMeetingsTests/CaptureContextTests.swift` (plain XCTest, no actor
isolation needed — that's the point). Cases:

1. `testIngestAfterFinish_isNoOp` — construct a context with a temp-file
   `AVAudioFile` (16 kHz mono Float32, same settings as
   `AudioRecorder.swift:91-99`), call `finish()`, then `ingest` a small synthetic
   buffer; assert `snapshotSamples()` stays empty and no error is returned.
2. `testIngestAccumulatesSamples` — ingest a 1600-frame sine buffer in the same
   format (converter can be `nil`-converter case: construct input buffer already in
   target format; if `CaptureContext` requires a converter, build one with
   identical in/out formats); assert `snapshotSamples().count == 1600` and the
   WAV file on disk is non-empty after `finish()`.
3. `testConcurrentIngestAndFinish_doesNotCrash` — from a background
   `DispatchQueue.concurrentPerform(iterations: 100)`, ingest buffers while the
   test thread calls `finish()` midway; assert no crash and `snapshotSamples()`
   after finish is stable. (This is a smoke test for the lock, not a proof.)

Model the file-format setup on the dictionary at `AudioRecorder.swift:91-99`.

**Verify**: `xcodebuild ... test` → `TEST SUCCEEDED`, including 3 new tests.

## Test plan

Covered in Step 3. Additionally the full existing suite must pass, and — if you can
launch the app — a manual smoke: start a recording, speak ~15 s (level meter moves,
live transcript appears), stop; the recording transcribes and the WAV in
`~/Library/Application Support/Synapse Meetings/audio/` plays. If you cannot run
the app, state that explicitly in your report so a human verifies.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `xcodebuild ... build` → `BUILD SUCCEEDED`
- [ ] `xcodebuild ... test` → `TEST SUCCEEDED`, including 3 new `CaptureContextTests`
- [ ] `grep -n "self?.handleTap\|self\.handleTap" SynapseMeetings/Services/AudioRecorder.swift` → no matches
- [ ] The tap closure body references no stored property of `AudioRecorder` except
  via `Task { @MainActor in ... }` (manual read of the closure — paste it in your report)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `AudioRecorder.swift` has drifted from the excerpts (in particular if plan 005
  landed first and already restructured `pcmBuffer` — the two plans must be
  reconciled by a human/advisor, not improvised).
- `AVAudioFile` writes fail from the non-main thread in your testing (they should
  not — AVAudioFile is thread-agnostic as long as access is serialized — but if
  reality disagrees, stop).
- You need to change the `onChunk` callback signature or `AppState`.
- Test 3 crashes even with the lock in place — that indicates a deeper AVFoundation
  issue; report findings.

## Maintenance notes

- Plan 005 (bounded live transcription) will change *what* `pcmBuffer` retains
  (drain-on-chunk). With this plan landed, that becomes a small, safe edit inside
  `CaptureContext` (`snapshotSamples()` → `drainSamples()`).
- Reviewer should scrutinize: lock ordering (single lock, no nesting — keep it that
  way), and that `finish()` is called before the context is dropped in every path
  (including the error path in `start`).
- This plan is a prerequisite for any future Swift 6 strict-concurrency adoption of
  this target.
