# Plan 005: Bound live-transcription cost — stop re-transcribing the whole meeting every 10 seconds

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat c234ef6..HEAD -- SynapseMeetings/Services/AudioRecorder.swift SynapseMeetings/Models/AppState.swift`
> If either file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition. **In particular**: if plan 004 landed,
> the PCM buffer lives in `CaptureContext` — the same logic applies, but the
> edit points move (see "If plan 004 landed first" notes inline).

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED (changes live-transcript UX quality; final transcript quality is untouched)
- **Depends on**: plans/004-audio-thread-isolation.md (recommended order; see drift note)
- **Category**: perf / bug
- **Planned at**: commit `c234ef6`, 2026-06-10

## Why this matters

The live-transcript feature does O(n²) work and holds the entire meeting in RAM:

1. **Memory**: every converted sample is appended to an in-memory `[Float]`
   (`pcmBuffer`) for the whole session — 16 kHz mono Float32 ≈ **230 MB per hour**,
   never drained until stop.
2. **CPU/ANE**: every 10 s, the *entire* buffer is copied, written out as a fresh
   WAV, and **re-transcribed from 0:00**. At minute 40, each tick transcribes 40
   minutes of audio. Total ASR work grows quadratically with meeting length.
3. **Pile-up**: `handleChunk` cancels the previous `Task`, but FluidAudio's
   `transcribe` doesn't observe cooperative cancellation mid-inference — once a
   single pass takes >10 s, full-length transcriptions stack up concurrently.

The fix: make each chunk **incremental** — export and transcribe only the samples
since the previous chunk, and **append** to the live transcript. The final
transcript is unaffected: it is produced after stop by a single full-file
transcription in `executePipeline` (`AppState.swift:363-399`), which this plan does
not touch. Trade-off accepted by the maintainer: the live preview loses Parakeet's
retroactive self-correction across chunk boundaries; the authoritative final
transcript keeps full quality.

## Current state

Relevant files:

- `SynapseMeetings/Services/AudioRecorder.swift` — buffer accumulation + chunk export.
- `SynapseMeetings/Models/AppState.swift` — chunk handling + live transcript state.

Accumulation, `AudioRecorder.swift:26-29` (or inside `CaptureContext` if plan 004
landed):

```swift
/// In-memory PCM samples written so far (mono float32). Used to materialize
/// a properly-finalized WAV snapshot for chunked transcription.
private var pcmBuffer: [Float] = []
private let pcmBufferQueue = DispatchQueue(label: "AudioRecorder.pcmBuffer")
```

Chunk export, `AudioRecorder.swift:149-186` (`fireChunk`) — snapshots the FULL
buffer every tick:

```swift
private func fireChunk() {
    guard let callback = onChunk, let format = targetFormat else { return }
    let snapshot: [Float] = pcmBufferQueue.sync { pcmBuffer }
    guard !snapshot.isEmpty else { return }
    // ... writes snapshot to a temp WAV, calls callback(tmp) ...
}
```

Chunk consumption, `AppState.swift:211-230` (`handleChunk`) — replaces the live
transcript with each full re-transcription:

```swift
private func handleChunk(_ url: URL) {
    liveTranscriptTask?.cancel()
    liveTranscriptTask = Task { [weak self] in
        guard let self else { return }
        do {
            let text = try await transcriber.transcribe(fileAt: url)
            try? FileManager.default.removeItem(at: url)
            guard !Task.isCancelled else { return }
            // Each chunk transcribes the full audio so far, so we replace
            // (not append) — that way Parakeet's evolving understanding
            // of context shows up cleanly without duplication artifacts.
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            self.liveTranscript = cleaned
            self.lastChunkTranscriptLength = cleaned.count
        } catch {
            NSLog("Live chunk transcription failed: \(error)")
            try? FileManager.default.removeItem(at: url)
        }
    }
}
```

Related state: `liveTranscript` / `lastChunkTranscriptLength` (`AppState.swift:22,32`),
reset in `startNewRecording` (`AppState.swift:182-183`). `liveTranscript` is
displayed in `RecordingDetailView` (live + transcribing views) — read-only consumers,
no changes needed there. Chunk cadence: `chunkInterval: TimeInterval = 10`
(`AudioRecorder.swift:37`).

The WAV-on-disk recording (`audioFile.write` in the tap path) is the authoritative
full recording and is NOT affected by draining the in-memory buffer.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate project | `xcodegen generate` | exit 0 |
| Build | `xcodebuild -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS' build` | `BUILD SUCCEEDED` |
| Tests | `xcodebuild -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS' test` | `TEST SUCCEEDED` |

## Scope

**In scope** (the only files you should modify):
- `SynapseMeetings/Services/AudioRecorder.swift` (drain-on-chunk)
- `SynapseMeetings/Models/AppState.swift` (append semantics in `handleChunk`)
- `SynapseMeetingsTests/` — extend `CaptureContextTests.swift` if plan 004 landed,
  otherwise no recorder tests are feasible (note it in your report)

**Out of scope** (do NOT touch):
- The final-transcription path: `executePipeline`'s `transcribeWithTimings` /
  `transcribe` calls and everything downstream (diarization, summarize).
- `TranscriptionService.swift` — no cancellation plumbing into FluidAudio; the
  incremental design makes chunk transcriptions short, which sidesteps the pile-up
  instead of fighting it.
- `chunkInterval` tuning, UI changes, `RecordingDetailView`.

## Git workflow

- Branch: `advisor/005-bounded-live-transcription`
- Commits: one per side (recorder drain, appstate append), e.g.
  `Drain PCM buffer per chunk so live transcription is incremental`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Drain the PCM buffer on each chunk

In `AudioRecorder.swift` (`fireChunk`), replace the full-snapshot read with a
drain, so memory and chunk size are bounded by one interval (~10 s ≈ 640 KB):

```swift
let snapshot: [Float] = pcmBufferQueue.sync {
    let s = pcmBuffer
    pcmBuffer.removeAll(keepingCapacity: true)
    return s
}
```

**If plan 004 landed first**: implement this as `drainSamples()` on
`CaptureContext` (lock-protected swap-and-clear) and call it from `fireChunk` in
place of `snapshotSamples()`.

Also update the stale doc comment on `pcmBuffer` (lines 26-27) to say "samples
since the last chunk export".

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`

### Step 2: Flush the tail on stop

Today, samples captured after the last 10 s tick are only in the WAV file — fine
for the final transcript, but with incremental live transcription the tail would
never appear live. That's acceptable (recording is ending), but `stop()` must not
leave a *pending chunk file orphaned*. Confirm `stop()` already invalidates
`chunkTimer` before clearing the buffer (it does — `AudioRecorder.swift:133-143`).
No code change expected; this step is a conscious check.

**Verify**: read `stop()`; confirm order: `chunkTimer?.invalidate()` precedes buffer
clearing. State the line numbers in your report.

### Step 3: Append instead of replace in `handleChunk`

In `AppState.swift`:

1. Replace the body of `handleChunk` so chunk text is appended:

```swift
private func handleChunk(_ url: URL) {
    let task = Task { [weak self] in
        guard let self else { return }
        do {
            let text = try await transcriber.transcribe(fileAt: url)
            try? FileManager.default.removeItem(at: url)
            guard !Task.isCancelled else { return }
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return }
            self.liveTranscript = self.liveTranscript.isEmpty
                ? cleaned
                : self.liveTranscript + " " + cleaned
        } catch {
            NSLog("Live chunk transcription failed: \(error)")
            try? FileManager.default.removeItem(at: url)
        }
    }
    liveTranscriptTask = task
}
```

   Key changes: **no cancellation of the previous task** (chunks are now disjoint
   audio — cancelling would drop a segment, and each chunk is ~10 s so transcription
   finishes well within the interval), and **append** with a space separator.
   Keep `liveTranscriptTask` assignment so `stopRecordingAndProcess` /
   `stopActiveRecordingAndProcess` can still cancel the in-flight one at stop
   (`AppState.swift:139,233`).

2. Delete the now-unused `lastChunkTranscriptLength` property
   (`AppState.swift:32`) and its two writes (`AppState.swift:183,224`).

3. Update the comment — the old "replace, not append" rationale no longer applies.

Ordering note: chunks arrive in order because `fireChunk` runs on the main-thread
timer and `transcriber.transcribe` calls are serialized through the single
`AsrManager`; out-of-order appends are not a realistic failure mode at 10 s
intervals, but if you see evidence otherwise during verification, STOP.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`, and
`grep -n "lastChunkTranscriptLength" SynapseMeetings/Models/AppState.swift` → no matches.

### Step 4: Tests

If plan 004 landed (CaptureContext exists), add to
`SynapseMeetingsTests/CaptureContextTests.swift`:

1. `testDrainSamples_emptiesBuffer` — ingest 1600 frames, `drainSamples()` returns
   1600 and a second `drainSamples()` returns 0.
2. `testDrainSamples_doesNotAffectFileOnDisk` — ingest, drain, finish; WAV file
   still contains the written frames (file size > 44-byte header).

If plan 004 has NOT landed, the queue-private buffer can't be tested directly;
rely on build + existing suite and say so in your report.

**Verify**: `xcodebuild ... test` → `TEST SUCCEEDED`

## Test plan

Step 4 above, plus the full existing suite. Manual smoke if the app can be
launched: record ≥30 s of speech; the live transcript should grow roughly every
10 s without rewriting earlier text; stop; the final transcript (from the full
WAV) should be complete including the final seconds. Memory check (optional but
ideal): record several minutes and observe the app's footprint stays flat in
Activity Monitor instead of growing ~4 MB/min.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `xcodebuild ... build` → `BUILD SUCCEEDED`
- [ ] `xcodebuild ... test` → `TEST SUCCEEDED`
- [ ] `grep -n "removeAll(keepingCapacity: true)" SynapseMeetings/Services/AudioRecorder.swift`
  → 1 match inside the chunk path (or the `drainSamples` equivalent in `CaptureContext`)
- [ ] `grep -n "lastChunkTranscriptLength" SynapseMeetings/` → no matches
- [ ] `grep -n "liveTranscriptTask?.cancel()" SynapseMeetings/Models/AppState.swift`
  → matches only in the two stop paths (`stopActiveRecordingAndProcess`,
  `stopRecordingAndProcess`), not in `handleChunk`
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts don't match the live code and the difference is more than plan 004's
  CaptureContext move (drift).
- You find evidence that `AsrManager` does NOT serialize concurrent `transcribe`
  calls (e.g. crashes or interleaved results when two chunk tasks overlap) — the
  append design assumes serialization; report before adding your own queueing.
- The live transcript visibly duplicates or drops words at every chunk boundary in
  manual testing beyond an occasional clipped word — boundary artifacts are
  expected to be minor; wholesale duplication means the drain is wrong.
- You're tempted to add overlap-and-merge logic between chunks — that's a design
  extension the advisor deliberately deferred; report instead.

## Maintenance notes

- Boundary artifacts: chunks are cut mid-word at 10 s marks. If users complain, the
  documented follow-up is a small overlap window (e.g. carry the last 1-2 s of
  samples into the next chunk and de-duplicate text) — deferred because the final
  transcript is unaffected.
- If plan 004 has not landed when this executes, the drain happens under
  `pcmBufferQueue` — plan 004's executor must then port the drain into
  `CaptureContext.drainSamples()`.
- Reviewer should scrutinize: the removed task-cancellation in `handleChunk`
  (intentional — see Step 3) and that stop paths still cancel the in-flight task.
