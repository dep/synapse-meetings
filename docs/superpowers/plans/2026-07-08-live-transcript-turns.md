# Live Transcript You/Them Turns Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The live transcript panel shows token-level You/Them speaker turns with linebreaks instead of one flat string, reusing the final pipeline's attribution.

**Architecture:** `CaptureContext` stops mono-mixing live-chunk samples and drains L/R separately; `fireChunk` writes stereo chunk WAVs; `AppState.handleChunk` transcribes with token timings and runs the existing `attributeTokensToChannels` per chunk, appending merged `SpeakerTurn`s to a new `liveTurns` published property; the two live-transcript views render turn rows.

**Tech Stack:** Swift 5.10, SwiftUI, AVFoundation, FluidAudio (Parakeet ASR), XCTest. XcodeGen project — no `project.yml` changes needed (no new files outside existing targets' source dirs).

## Global Constraints

- Build/test: `xcodebuild test -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS'` (run `xcodegen generate` first if `project.yml` changed — it doesn't in this plan).
- `AppState` is `@MainActor`; background tasks touching it must hop to main.
- Speaker labels: mic = `"You"`, system = `"Them"`; unlabeled live turns use `""`.
- Chunk WAV layout must match the main file: L = mic, R = system.
- Test bundle imports `@testable import Synapse_Meetings`.

---

### Task 1: Turn-append merge logic (`AppState.appendingTurns`)

**Files:**
- Modify: `SynapseMeetings/Models/AppState.swift` (near `formatSpeakerTurns`, ~line 719)
- Test: `SynapseMeetingsTests/AppStatePipelineTests.swift`

**Interfaces:**
- Produces: `static func appendingTurns(_ new: [SpeakerTurn], to existing: [SpeakerTurn]) -> [SpeakerTurn]` on `AppState`. Merges `new.first` into `existing.last` when `speakerLabel`s are equal (text joined with one space, `endSec` extended).

- [x] Steps 1–5: failing tests → implement → pass → commit (see repo history)

Tests: same-label merge, different-label append, empty-existing, empty-new, unlabeled ("") merge, multi-turn new batch where only the first merges.

### Task 2: Stereo chunk buffers in `CaptureContext`

**Files:**
- Modify: `SynapseMeetings/Services/AudioRecorder.swift` (`CaptureContext.pcmBuffer`, `appendSamples`, `drainSamples`, `snapshotSamples`)
- Test: `SynapseMeetingsTests/CaptureContextTests.swift`

**Interfaces:**
- Produces: `struct DrainedSamples { let left: [Float]; let right: [Float]; var isStereo: Bool }` (file-level, in AudioRecorder.swift); `CaptureContext.drainSamples() -> DrainedSamples`.
- `snapshotSamples() -> [Float]` keeps returning the left/mono buffer (test-only API).

- [x] Update `testDualTrack_drainReturnsMonoMix` → `testDualTrack_drainReturnsBothChannels` (L constant 0.5, R constant 0.3); update `testDrainSamples_emptiesBuffer` / `testCombine_thenDualTrackIngest_routesCorrectly` to `.left`/`.right`; run (fail); implement dual buffers (`pcmL`/`pcmR`; mono layout leaves `pcmR` empty); run (pass); commit.

### Task 3: Stereo chunk WAV export

**Files:**
- Modify: `SynapseMeetings/Services/AudioRecorder.swift` (`fireChunk`; new static helper)
- Test: `SynapseMeetingsTests/CaptureContextTests.swift` (new `ChunkWAVTests` class)

**Interfaces:**
- Produces: `static func writeChunkWAV(_ samples: DrainedSamples, sampleRate: Double) throws -> URL` on `AudioRecorder` — writes mono WAV when `right` is empty, else stereo (L = left, R = right; right zero-padded/truncated to left's length). `fireChunk` calls it and passes the URL to `onChunk`.

- [x] Failing tests (stereo → 2-ch WAV with per-channel constants; mono → 1-ch) → implement → pass → commit.

### Task 4: `AppState.liveTurns` + attributed `handleChunk`

**Files:**
- Modify: `SynapseMeetings/Models/AppState.swift` (`liveTranscript` → `liveTurns`, `startNewRecording`, `handleChunk`)

**Interfaces:**
- Produces: `@Published private(set) var liveTurns: [SpeakerTurn]`. `handleChunk` uses `transcribeWithTimings`, `ChannelEnvelopes.load` (detached task), `attributeTokensToChannels(tokens:envelopes:systemSegments: nil)`, falls back to one `SpeakerTurn(speakerLabel: "", …, text: cleanedText)` for mono/no-timings, appends via `appendingTurns`.

- [x] Implement (glue — covered by Tasks 1–3 unit tests + existing ChannelAttributionTests); fix all `liveTranscript` references; build; commit with Task 5.

### Task 5: Turn-row rendering in the live views

**Files:**
- Modify: `SynapseMeetings/Views/RecordingDetailView.swift` (`RecordingInProgressView`, `TranscribingView`; new `LiveTurnsView`)

**Interfaces:**
- Consumes: `app.liveTurns: [SpeakerTurn]`.
- Produces: `private struct LiveTurnsView: View` — `VStack` of turn rows: uppercase bold caption label (accent for "You", secondary otherwise, hidden when empty) above turn text; `textSelection(.enabled)`; bottom element keeps `.id("transcript")` for auto-scroll; `onChange(of: app.liveTurns)`.

- [x] Implement both call sites; build app target; run full suite; commit.

### Task 6: Verification

- [x] `xcodebuild build` (app target) and `xcodebuild test` full suite pass.
- [x] Spec ↔ implementation cross-check; commit docs.
