# Plan 001: Preserve the existing summary when a re-summarize attempt fails

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat c234ef6..HEAD -- SynapseMeetings/Models/AppState.swift`
> If the file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug
- **Planned at**: commit `c234ef6`, 2026-06-10

## Why this matters

When the user clicks "Summarize" on a finished recording, `AppState.resummarize`
**persists `summaryMarkdown = ""` before the Anthropic API call runs**. If the call
fails — missing API key (the key is optional in this app!), network error, 4xx/5xx —
the recording lands in `.failed` with an empty summary. The previous summary,
**including any manual edits the user made**, is permanently destroyed. The
confirmation dialog only warns that a *successful* pass replaces the summary; data
loss on *failure* is never consented to. The fix: never clear the old summary —
replace it only after a new one arrives.

## Current state

Relevant files:

- `SynapseMeetings/Models/AppState.swift` — `@MainActor` app coordinator; owns the
  transcribe→summarize pipeline. This is the only file you will modify.
- `SynapseMeetings/Views/RecordingDetailView.swift` — read-only context: the
  "Summarize" button (line ~50) and confirmation dialog (line ~81) that trigger
  `app.resummarize(recording)`. Do not modify.

The bug, at `AppState.swift:314-337` (`resummarize`). Note line 332 clearing the
summary before the pipeline runs:

```swift
func resummarize(_ recording: Recording) {
    var updated = recording
    if updated.transcript.isEmpty {
        // Note-only: feed the existing summary content back in ...
        NotificationCenter.default.post(
            name: .flushPendingEdits,
            object: nil,
            userInfo: ["recordingID": recording.id]
        )
        // Re-fetch after the synchronous flush.
        let latest = store.recordings.first(where: { $0.id == recording.id }) ?? recording
        updated = latest
        let body = latest.summaryMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return }
        updated.transcript = latest.summaryMarkdown
    }
    updated.summaryMarkdown = ""          // ← the data-loss line
    updated.lastError = nil
    updated.status = .summarizing
    store.upsert(updated)
    runPipeline(for: updated.id)
}
```

The pipeline decides whether to summarize by checking emptiness, at
`AppState.swift:353-357` and `AppState.swift:403`:

```swift
private func runPipeline(for id: Recording.ID) {
    Task { [weak self] in
        await self?.executePipeline(id: id)
    }
}

private func executePipeline(id: Recording.ID) async {
    guard var recording = store.recordings.first(where: { $0.id == id }) else { return }
    // ... transcription step (only if recording.transcript.isEmpty) ...
    // Summarize
    if recording.summaryMarkdown.isEmpty {          // ← line 403
        do {
            recording.status = .summarizing
            ...
            recording.summaryMarkdown = combined
            ...
            recording.status = .ready
            store.upsert(recording)
        } catch {
            recording.status = .failed
            recording.lastError = "Summarization failed: \(error.localizedDescription)"
            store.upsert(recording)
            return
        }
    } else {
        recording.status = .ready
        store.upsert(recording)
    }
}
```

`retry(_:)` at `AppState.swift:339-351` re-enters the pipeline after a failure: it
sets `.transcribing` if the transcript is empty, `.summarizing` if the summary is
empty, else `.ready`. With this fix, a failed re-summarize leaves the OLD summary in
place, so `retry` will set the recording back to `.ready` and the user gets their old
summary back. That is the intended behavior.

Conventions: the codebase is Swift 5.10, `@MainActor` classes, no third-party
test frameworks (plain XCTest). Match existing code style (4-space indent,
`// MARK: -` sections).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate project | `xcodegen generate` | exit 0, writes `SynapseMeetings.xcodeproj` |
| Build | `xcodebuild -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS' build` | `BUILD SUCCEEDED` |
| Tests | `xcodebuild -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS' test` | `TEST SUCCEEDED` |

(First build resolves SPM packages — FluidAudio, Sparkle — and may take several minutes.)

## Scope

**In scope** (the only files you should modify):
- `SynapseMeetings/Models/AppState.swift`

**Out of scope** (do NOT touch, even though they look related):
- `SynapseMeetings/Views/RecordingDetailView.swift` — the dialog copy is acceptable as-is.
- `SynapseMeetings/Services/AnthropicService.swift` — the API client is not at fault.
- Plan 002 covers unsaved-edit flushing; do not add autosave behavior here.
- Plan 006 covers stale-snapshot merging in `executePipeline`; do not refactor the
  whole pipeline here. Only the minimal changes below.

## Git workflow

- Branch: `advisor/001-preserve-summary-on-failed-resummarize`
- Single commit; message style matches repo history (sentence case, imperative),
  e.g. `Fix resummarize destroying the existing summary on API failure`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Thread a `forceSummarize` flag through the pipeline

In `SynapseMeetings/Models/AppState.swift`:

1. Change `runPipeline` and `executePipeline` signatures to carry a flag,
   defaulting to `false` so the two other call sites (`stopRecordingAndProcess`
   line ~248, `retry` line ~350) compile unchanged:

```swift
private func runPipeline(for id: Recording.ID, forceSummarize: Bool = false) {
    Task { [weak self] in
        await self?.executePipeline(id: id, forceSummarize: forceSummarize)
    }
}

private func executePipeline(id: Recording.ID, forceSummarize: Bool = false) async {
```

2. Change the summarize-step condition at line ~403 from
   `if recording.summaryMarkdown.isEmpty {` to:

```swift
if forceSummarize || recording.summaryMarkdown.isEmpty {
```

**Verify**: `xcodebuild -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS' build` → `BUILD SUCCEEDED`

### Step 2: Stop clearing the summary in `resummarize`

In `resummarize(_:)`:

1. Delete the line `updated.summaryMarkdown = ""`.
2. Change the final call from `runPipeline(for: updated.id)` to
   `runPipeline(for: updated.id, forceSummarize: true)`.

Nothing else in `resummarize` changes — the note-only branch (feeding the current
summary back in as the transcript) must keep working exactly as before.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`, and
`grep -n 'summaryMarkdown = ""' SynapseMeetings/Models/AppState.swift` → no matches.

### Step 3: Confirm the success path still replaces the summary

Read the summarize step in `executePipeline` and confirm that on success it assigns
`recording.summaryMarkdown = combined` (replacing the old value) — it already does;
no code change expected. This step exists so you consciously confirm that a forced
run *replaces* rather than appends.

**Verify**: `grep -n "recording.summaryMarkdown = combined" SynapseMeetings/Models/AppState.swift` → exactly 1 match.

## Test plan

Automated pipeline tests require the service-injection seam built in plan 003 —
**a regression test for this exact behavior is specified there** (stub summarizer
that throws; assert `summaryMarkdown` unchanged). Do not attempt to unit-test the
pipeline in this plan; `AppState` cannot yet be constructed safely in tests.

For this plan:
- Run the full existing suite: `xcodebuild ... test` → `TEST SUCCEEDED`
  (existing tests in `SynapseMeetingsTests/` cover `extractTitle`,
  `formatSpeakerTurns`, `alignTokensToSpeakers`, prompt rendering, the store —
  none should be affected).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `xcodebuild ... build` → `BUILD SUCCEEDED`
- [ ] `xcodebuild ... test` → `TEST SUCCEEDED`
- [ ] `grep -n 'summaryMarkdown = ""' SynapseMeetings/Models/AppState.swift` → no matches
- [ ] `grep -n "forceSummarize" SynapseMeetings/Models/AppState.swift` → ≥3 matches
  (signature ×2, condition ×1, plus the `resummarize` call site)
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `AppState.swift` no longer matches the "Current state" excerpts (drift).
- The `forceSummarize` default-parameter change breaks a call site not listed here
  (search hits for `runPipeline(` other than `stopRecordingAndProcess`, `retry`,
  `resummarize`).
- You find yourself wanting to modify `executePipeline`'s catch block or upsert
  pattern beyond the one-line condition change — that's plan 006's territory.

## Maintenance notes

- Plan 003 adds the unit test that locks this behavior in; if you execute plans out
  of order, make sure that test still gets written.
- Reviewer should scrutinize: the `retry()` interaction — after a failed forced
  re-summarize, retry now lands on `.ready` with the old summary intact (expected),
  rather than re-attempting the summarize. Re-running "Summarize" is the retry path
  for that flow.
- Deferred: surfacing `lastError` non-modally for `.ready` recordings (today errors
  only show in the `.failed` full-pane view).
