# Compliance: Privacy Policy, Attribution, Open Source Licensing — Design

**Date:** 2026-07-13
**Status:** Approved

## Problem

The repo has an MIT LICENSE and README credits, but the shipped app does not
satisfy its dependencies' license terms, and there is no privacy policy for an
app that records audio and sends transcripts to third-party APIs.

Gaps:

1. **License reproduction.** Sparkle (MIT-style + bundled bsdiff/sais-lite/ed25519
   notices) and FluidAudio (Apache 2.0, plus its own fastcluster/vbx notices)
   require their license texts to accompany distributions. A README link does not.
2. **Model attribution.** The ASR model derives from NVIDIA Parakeet TDT 0.6B v3
   (CC-BY-4.0) via FluidInference's Core ML conversion (Apache 2.0). Diarization
   derives from pyannote speaker-diarization-community-1 (CC-BY-4.0) via
   FluidInference's Core ML conversion (CC-BY-4.0). CC-BY-4.0 requires attribution.
3. **Privacy policy.** None exists. Data flows: mic + system audio recording,
   local JSON/audio storage, on-device transcription/diarization, optional
   transcript transmission to Anthropic or OpenRouter, optional GitHub pushes,
   local calendar reads, Keychain secrets, Sparkle update checks, Hugging Face
   model downloads.

## Design

1. **`THIRD-PARTY-NOTICES.md` (repo root, single source of truth).** Sections:
   Sparkle full LICENSE; FluidAudio (Apache 2.0 full text) plus its
   fastcluster and vbx notices; ML model attributions (Parakeet/NVIDIA,
   pyannote/FluidInference) with CC-BY-4.0 links.
2. **`PRIVACY.md` (repo root).** Plain-language policy covering the data flows
   above, the no-analytics/no-telemetry stance, and data deletion.
3. **In-app acknowledgements.** `THIRD-PARTY-NOTICES.md` is added to the app
   target's resources in `project.yml` (root file referenced directly — no
   duplicate copy), so the DMG carries the license texts. The existing Settings
   About tab gains an "Acknowledgements" button that opens a scrollable sheet
   rendering the bundled file, and a "Privacy Policy" link to the GitHub page.
4. **README.** Add Acknowledgements section linking THIRD-PARTY-NOTICES.md and
   a Privacy link to PRIVACY.md.
5. **Version bump** to 0.7.3 / build 26 as its own commit, then release via
   EXPORT-SIGNED-APP.

## Testing

XCTest (TDD): assert the app bundle contains `THIRD-PARTY-NOTICES.md` and that
it includes the expected license markers (Sparkle, Apache License, CC BY 4.0).
UI sheet is exercised by building; no UI test harness exists in this repo.

## Alternatives considered

- **Dedicated "Licenses" Settings tab** with per-library disclosure groups —
  nicer UX, more code, same legal effect. Rejected for simplicity.
- **Hosted privacy policy on synapseapps.io** — better for a multi-app
  ecosystem, but requires site work outside this repo. Rejected; PRIVACY.md
  renders at a stable GitHub URL.
- **Link-only acknowledgements in-app** — does not place license texts in the
  distribution; fails the actual license terms. Rejected.
