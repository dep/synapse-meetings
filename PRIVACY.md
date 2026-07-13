# Privacy Policy — Synapse Meetings

_Last updated: 2026-07-13_

Synapse Meetings is a macOS app that records meetings, transcribes them on
your device, and — only when you enable it — summarizes transcripts with an
AI provider and commits results to a GitHub repository. This policy explains
what data the app touches and where it goes.

**The short version: your recordings stay on your Mac. Nothing is sent
anywhere unless you configure a feature that sends it, using your own
accounts and API keys. The app has no servers, no accounts, no analytics,
and no telemetry.**

## Data stored on your Mac

- **Audio recordings** (microphone and, if enabled, system audio) are saved
  under `~/Library/Application Support/Synapse Meetings/audio/`.
- **Transcripts, summaries, and recording metadata** are saved as JSON under
  `~/Library/Application Support/Synapse Meetings/recordings/`.
- **API keys and tokens** (Anthropic, OpenRouter, GitHub) are stored in the
  macOS Keychain, never in plain files or preferences.
- **Preferences** (model choice, prompts, hotkeys, audio device, toggles) are
  stored in standard macOS user defaults.

None of this data is uploaded by the app on its own.

## Processing that happens on your device

- **Transcription** runs locally on the Apple Neural Engine using the
  Parakeet Core ML model. Audio never leaves your Mac for transcription.
- **Speaker diarization** (optional) also runs entirely on-device.
- **Calendar events**: with your permission, the app reads your calendar via
  Apple's EventKit to show today's events beside your recordings. Calendar
  data is read locally and is not transmitted.

## Data sent to third parties — only when you enable it

- **AI summarization (optional).** If you add an Anthropic or OpenRouter API
  key and run summarization, the meeting transcript (including a
  speaker-labeled version when diarization is on) and your prompt are sent to
  that provider to generate the summary. This uses your own API key and is
  governed by the provider's terms:
  [Anthropic](https://www.anthropic.com/legal/privacy) /
  [OpenRouter](https://openrouter.ai/privacy).
- **Commit to GitHub (optional).** If you add a GitHub personal access token
  and use commit-to-repo, transcripts and summaries you choose to commit are
  pushed to the repository you configure, under
  [GitHub's privacy terms](https://docs.github.com/en/site-policy/privacy-policies).

If you never configure these features, the app makes no requests to these
services.

## Other network traffic

- **Software updates.** The app checks for updates via Sparkle by fetching an
  appcast file from GitHub. No personal data or system profile is sent; like
  any web request, GitHub sees your IP address.
- **Model downloads.** On first use of transcription or diarization, the app
  downloads Core ML model weights from Hugging Face. This is a plain file
  download; no personal data is sent.

## What the app does not do

- No analytics, tracking, or telemetry of any kind.
- No accounts, and no servers operated by Synapse Meetings.
- No selling or sharing of data — the app never possesses your data anywhere
  except on your Mac.

## Deleting your data

- Delete individual recordings from within the app, or remove
  `~/Library/Application Support/Synapse Meetings/` to erase everything.
- Remove stored keys from Keychain Access (or overwrite them in the app's
  Settings).
- Data you sent to Anthropic, OpenRouter, or GitHub is subject to those
  services' retention policies and deletion tools.

## Permissions the app requests

- **Microphone** — to record your side of meetings.
- **System audio capture** — to record the other side of headphone calls.
- **Calendars** — to display today's events (read-only).

Each is requested only when first needed, and the app functions without any
permission you decline (with the corresponding feature unavailable).

## Changes and contact

Changes to this policy are published in this repository with the app's
release notes. Questions or concerns: open an issue at
<https://github.com/dep/synapse-meetings/issues>.
