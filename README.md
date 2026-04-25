# Synapse Meetings

A macOS app for recording meetings, transcribing them locally, and committing the results to GitHub.

Part of the Synapse ecosystem alongside [Synapse Notes](https://github.com/dep/synapse-notes).

## Download

**[⬇️ Download the latest release](https://github.com/dep/synapse-meetings/releases/latest)**

1. Download `SynapseMeetings-<version>.dmg` from the release page.
2. Open the DMG and drag **Synapse Meetings** to your Applications folder.
3. Launch it from Applications or Spotlight.

The app is signed with a Developer ID and notarized by Apple, so it should launch without Gatekeeper prompts on macOS 14.0 or later.

## Auto-updates

Synapse Meetings ships with [Sparkle](https://sparkle-project.org), so once you've installed it you'll get future updates automatically. You can also trigger a check manually from **Synapse Meetings → Check for Updates…** in the menu bar.

## Requirements

- macOS 14.0 (Sonoma) or later
- **Apple Silicon strongly recommended.** Transcription runs on the Apple Neural Engine via Core ML — Intel Macs will fall back to CPU and may be unusably slow.
- Microphone access (you'll be prompted on first recording)
- An [Anthropic API key](https://console.anthropic.com/) for AI summarization (optional)
- A [GitHub personal access token](https://github.com/settings/tokens) for commit-to-repo (optional)

## Features

- **Local audio recording** with system + microphone capture
- **On-device transcription** powered by [FluidAudio](https://github.com/FluidInference/FluidAudio) using the [Parakeet TDT 0.6B v3](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml) Core ML model (first launch downloads ~470MB of model weights)
- **AI-assisted summarization** via the Anthropic API
- **Commit to GitHub** — push transcripts and summaries directly to a repo from the app
- **Auto-updating** via Sparkle

## Building from source

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
git clone git@github.com:dep/synapse-meetings.git
cd synapse-meetings
xcodegen generate
open SynapseMeetings.xcodeproj
```

Then build and run the `SynapseMeetings` scheme in Xcode.

## Releasing

See [`.agents/commands/EXPORT-SIGNED-APP.md`](.agents/commands/EXPORT-SIGNED-APP.md) for the full sign + notarize + Sparkle release pipeline.
