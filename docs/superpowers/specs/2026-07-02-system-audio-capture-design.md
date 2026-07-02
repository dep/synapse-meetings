# System Audio Capture (Dual-Track "You / Them") — Design

**Date:** 2026-07-02
**Status:** Approved

## Problem

Synapse Meetings records only the microphone (`AVAudioEngine.inputNode` tap in
`Services/AudioRecorder.swift`). When the user wears headphones, remote
participants' audio goes straight to the headphones and never reaches the mic,
so transcripts contain only the user's side of the call. This makes the app
unusable for headphone meetings (the primary use case).

## Goal

Capture system audio output alongside the microphone so both sides of a call
are recorded, transcribed, and summarized — and use the two separate sources to
label transcript speech as **You** (mic) vs **Them** (system audio), improving
speaker attribution beyond what diarization alone provides.

## Non-goals

- Per-app capture selection or app exclusion lists (we tap the whole system
  output mix).
- Echo cancellation for speaker (non-headphone) playback. Mic bleed is
  tolerated; attribution prefers the system channel when both are hot.
- Support below macOS 14.4 (those systems keep today's mic-only behavior).
- In-app audio playback changes (the app has no playback feature).

## Decisions made during brainstorming

1. **Dual-track + attribution** (not a simple mix-down): mic and system audio
   are kept as separate channels; channel energy drives You/Them labeling.
2. **All system audio** is captured (excluding Synapse's own process), not a
   per-app picker.
3. **Core Audio process taps** (macOS 14.4+) are the capture technology, not
   ScreenCaptureKit (avoids the Screen Recording permission) and not a virtual
   audio driver (no install friction).

## Architecture

### 1. Capture layer

**New service `Services/SystemAudioTap.swift`** (`@available(macOS 14.4, *)`):

- Creates a global-mixdown process tap via `CATapDescription` /
  `AudioHardwareCreateProcessTap`, excluding Synapse's own PID so app sounds
  are not captured.
- Creates an **aggregate device** (`AudioHardwareCreateAggregateDevice`)
  containing the selected input device (or system default) **and** the tap,
  with drift compensation enabled. Because both sources live in one aggregate,
  their buffers arrive sample-aligned in a single render callback — no manual
  clock alignment.
- Exposes: `activate(preferredMicUID:) throws -> ActivationResult` (aggregate
  device ID + mic channel count) and an idempotent `teardown()`. Availability
  is checked at call sites via `#available(macOS 14.4, *)`; permission denial
  surfaces as an activation failure and falls back to mic-only (no separate
  permission-state API).

**`AudioRecorder` changes (minimal):**

- When system capture is enabled + supported + permitted, `start(writingTo:)`
  asks `SystemAudioTap` for the aggregate device and points the existing
  engine's input at it — reusing the same
  `kAudioOutputUnitProperty_CurrentDevice` mechanism already in
  `applyPreferredInputDevice()`. Otherwise the current mic-only path runs
  unchanged.
- The input format then contains mic channels followed by tap channels (order
  follows the aggregate's sub-device list). `CaptureContext` routes: mic
  channel(s) → output channel 0 (L, "You"), tap channels downmixed → output
  channel 1 (R, "Them").
- Level meter continues to reflect the mic channel.

### 2. File format & persistence

- Still one WAV per recording at the same path (`RecordingStore.audioURL`),
  16 kHz Float32 — but **2 channels** when system capture is active:
  **L = mic ("You"), R = system ("Them")**. Mic-only recordings stay mono.
- `Recording` gains `hasSystemAudio: Bool`, decoded with a default of `false`
  so existing persisted JSON loads unchanged.
- Live-transcription chunks (`CaptureContext.drainSamples()` →
  `AudioRecorder.fireChunk`) export the **mono mix** (average of L and R), so
  the live transcript includes remote participants. Chunk WAVs remain mono.

### 3. Pipeline & attribution

- Full-pass ASR (`TranscriptionService`) and `DiarizationService` are
  unchanged: both already load/downmix input to 16 kHz mono
  (`DiarizationService.swift` explicitly; FluidAudio's loader for ASR).
- **New helper `ChannelAttribution`** (pure function, unit-testable): given
  token timestamp windows and the stereo file, compare per-window RMS of L vs
  R → label each token **You** or **Them**. Tie-break: when both channels are
  hot (speaker bleed without headphones), **R (Them) wins**.
- In `AppState.executePipeline(id:)`, when `hasSystemAudio`:
  - Diarization **off** → transcript lines labeled `You:` / `Them:` via
    channel attribution (reusing the `alignTokensToSpeakers` reassembly
    machinery for SentencePiece pieces).
  - Diarization **on** → diarization runs on the **system (R) channel only**;
    remote speakers become `Speaker 1`, `Speaker 2`, …; mic-attributed tokens
    are always `You`. The user's voice never pollutes remote speaker clusters.
- When `hasSystemAudio` is false, the pipeline behaves exactly as today.

### 4. Settings, permission & fallback

- New `@AppStorage` toggle: **"Capture system audio (both sides of headphone
  calls)"** — default **on** where supported; on macOS < 14.4 the control is
  disabled with an explanatory caption.
- `project.yml` Info.plist gains `NSAudioCaptureUsageDescription`
  (regenerate the project with `xcodegen generate` after editing). First
  capture triggers the macOS "record system audio" prompt — audio-only TCC,
  not Screen Recording.
- **Fallback rule:** any failure (permission denied, tap/aggregate creation
  error, unsupported OS) degrades to today's mic-only mono recording. The
  recording proceeds; a one-line, non-blocking notice is surfaced (e.g. via
  `lastError`-style published message: "System audio unavailable — recorded
  microphone only"). Recording must never be blocked by this feature.
- Dev/test note: ad-hoc-signed local builds get TCC prompts silently denied
  (known repo gotcha). Verifying the permission flow end-to-end requires a
  Developer ID-signed build, as with the microphone permission.

## Error handling summary

| Failure | Behavior |
|---|---|
| macOS < 14.4 | Toggle disabled; mic-only path |
| Permission denied | Mic-only + notice; no retry loop |
| Tap/aggregate creation fails | Mic-only + notice; tap/aggregate torn down |
| Aggregate dies mid-recording (device unplug) | Existing engine error surface (`lastError`); same as today's mic unplug |

## Testing

- **`CaptureContext`**: stereo channel routing (mic→L, tap-downmix→R) and
  mono mix in `drainSamples()`, using the existing no-converter test seam with
  synthetic multichannel buffers.
- **`ChannelAttribution`**: synthetic two-channel energy patterns → expected
  You/Them labels, including the both-hot tie-break.
- **`Recording`**: JSON decode back-compat (missing `hasSystemAudio` →
  `false`).
- **Pipeline**: `AppState.init(store:makeSummarizer:)` stub-injected test
  asserting `You`/`Them` labels flow into the summarizer input for a
  `hasSystemAudio` recording.
- `SystemAudioTap` itself is thin OS-API glue; it is exercised manually (needs
  real TCC + hardware), with its failure paths covered via the fallback tests.

## Out of scope / future

- Per-app exclusions (e.g. music players) if "Them" pollution proves annoying.
- Echo cancellation for speaker playback.
- Exposing You/Them balance in the UI (waveforms, per-speaker mute).
