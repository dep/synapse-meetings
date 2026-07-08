# Live Transcript You/Them Turns — Design

**Date:** 2026-07-08
**Status:** Approved

## Problem

The live "transcription preview" panel (shown while recording and while
transcribing) renders `AppState.liveTranscript` — a flat string appended
chunk-by-chunk every ~10 s — as one unbroken wall of text. Recordings are now
dual-track (L = mic = "You", R = system audio = "Them"), and the *final*
transcript already separates speaker turns with linebreaks
(`formatSpeakerTurns`), but the live path mono-mixes both channels before ASR
(`CaptureContext.appendSamples`), throwing away the channel information.

## Goal

Live transcript shows token-level You/Them turns, visually separated, using
the exact same attribution logic as the final pass. Mic-only recordings keep
today's flat flowing text.

## Decisions (user-approved)

- **Fidelity:** token-level attribution per chunk (same as final pass), not
  chunk-level labeling or bare paragraph breaks.
- **Rendering:** styled turn rows (small bold uppercase speaker label above
  each turn's text), not plain `You:` text prefixes. Data model becomes
  `[SpeakerTurn]`, matching the final pipeline.

## Design

### 1. Capture layer — stereo live chunks (`AudioRecorder.swift`)

`CaptureContext` keeps left (mic) and right (system) chunk sample buffers
separately instead of mono-mixing. `drainSamples()` returns a
`DrainedSamples { left, right }` value (right empty for mono recordings).
`fireChunk` writes a **stereo** chunk WAV (L = mic, R = system — same layout
as the main recording file) when dual-track, mono otherwise. Chunk WAV
writing is extracted to a testable static helper on `AudioRecorder`.

### 2. Live chunk pipeline (`AppState.handleChunk`)

For each chunk: `transcribeWithTimings(fileAt:)` (instead of plain
`transcribe`), `ChannelEnvelopes.load(from:)` on the chunk WAV, then the
existing `attributeTokensToChannels(tokens:envelopes:systemSegments: nil)` —
unchanged, so live and final You/Them decisions agree. No diarization live,
so labels are only "You"/"Them" (never "Speaker N"). If the chunk is mono or
token timings are missing, fall back to a single unlabeled turn containing
the chunk's plain text.

### 3. Data model (`AppState`)

`@Published liveTranscript: String` becomes
`@Published liveTurns: [SpeakerTurn]` (reusing the existing `SpeakerTurn`
type; unlabeled turns use an empty `speakerLabel`). Appending merges: when
the first new turn's label equals the last existing turn's label, their text
concatenates (single space) and `endSec` extends, so one speaker talking
across a chunk boundary stays one block. Merge logic is a pure static
function with unit tests.

### 4. View (`RecordingDetailView.swift`)

Both renders of the live transcript (recording view, transcribing view)
switch to a shared turn-list view: for each turn, a small bold uppercase
caption label (**YOU** in accent color, everything else secondary) above the
turn text, spacing between turns, auto-scroll-to-bottom preserved. Turns with
an empty label render with no header — mic-only recordings look like today.

## Out of scope

- Final transcript format (already turn-separated).
- Diarized "Speaker N" labels in the live view.
- Pre-existing possibility of out-of-order chunk completion (merge logic
  tolerates either order gracefully).

## Testing

- `appendingTurns` merge: same-label merge, label alternation, unlabeled
  merge, empty cases.
- `CaptureContext`: dual-track drain returns both channels; existing drain
  tests updated to the new return type.
- Chunk WAV helper: stereo drain → 2-channel WAV with correct per-channel
  content; mono drain → 1-channel WAV.
- Attribution itself already covered by `ChannelAttributionTests` (logic
  reused untouched).
