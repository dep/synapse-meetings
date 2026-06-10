# Plan 006: Stop the pipeline from writing back stale Recording snapshots

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat c234ef6..HEAD -- SynapseMeetings/Models/AppState.swift`
> Plans 001 and 003 intentionally modify this file (a `forceSummarize` parameter
> and a `makeSummarizer` seam). Those exact changes are expected drift — proceed.
> Any OTHER structural change to `executePipeline` is a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/003-pipeline-test-seam-and-ci.md (required — the lost-update test needs the seam)
- **Category**: bug (latent)
- **Planned at**: commit `c234ef6`, 2026-06-10

## Why this matters

`AppState.executePipeline` fetches a `Recording` value **once**, then performs
minutes-long async steps (on-device transcription, a network call to Claude), and
after each step writes the **entire stale struct** back with `store.upsert(...)`.
Any field changed elsewhere in the meantime — attendees, live notes, title, commit
metadata — is silently reverted. Today the UI mostly gates editing on `.ready`
status, so the bug is latent; but every new edit surface (rename-in-list, attendee
edits during processing, a future sync feature) re-arms it. The fix is a
fetch-mutate-upsert helper so the pipeline only ever writes the fields it owns.
This also removes the dead `pipelineErrors` property while we're in the file.

## Current state

One file to modify: `SynapseMeetings/Models/AppState.swift`.

The pattern, `AppState.swift:359-467` (`executePipeline`) — note the single fetch
at the top and the five whole-struct upserts after long awaits:

```swift
private func executePipeline(id: Recording.ID) async {
    guard var recording = store.recordings.first(where: { $0.id == id }) else { return }

    // Transcribe + diarize (in parallel when both are needed)
    if recording.transcript.isEmpty {
        do {
            recording.status = .transcribing
            store.upsert(recording)                       // upsert #1
            let audioURL = store.audioURL(for: recording)
            ...
            let asrResult = try await asrTask             // ← minutes pass
            ...
            recording.transcript = asrResult.text
            ...
            store.upsert(recording)                       // upsert #2 — stale fields written back
        } catch {
            recording.status = .failed
            recording.lastError = "Transcription failed: ..."
            store.upsert(recording)                       // upsert #3
            return
        }
    }

    // Summarize
    if recording.summaryMarkdown.isEmpty {
        do {
            recording.status = .summarizing
            store.upsert(recording)
            ...
            let summaryOnly = try await anthropic.summarize(...)  // ← network call
            ...
            recording.summaryMarkdown = combined
            if recording.calendarEventTitle == nil,
               let extracted = Self.extractTitle(from: summaryOnly), !extracted.isEmpty {
                recording.title = extracted
            }
            recording.status = .ready
            store.upsert(recording)                       // stale write-back again
        } catch { ... }
    } else {
        recording.status = .ready
        store.upsert(recording)
    }
}
```

(After plans 001 + 003 land, the signature is
`func executePipeline(id: Recording.ID, forceSummarize: Bool = false) async`, the
summarize condition includes `forceSummarize ||`, and the summarizer comes from
`makeSummarizer` — same structure otherwise.)

The store API, `RecordingStore.swift:75-82`: `upsert(_:)` replaces by `id` and
persists to disk. `@MainActor` everywhere, so fetch-mutate-upsert with no
suspension point in between is atomic with respect to UI edits.

Pipeline-owned fields (the ONLY fields the pipeline may write): `transcript`,
`speakerTurns`, `summaryMarkdown`, `status`, `lastError`, and `title` (only in the
calendar-title-absent extraction case). Everything else — `attendees`, `liveNotes`,
`calendarEventTitle`, `committed*`, `duration`, `createdAt` — belongs to other
writers and must flow through untouched.

Dead code to remove, `AppState.swift:21` (written nowhere, read nowhere — verified
by repo-wide grep at planning time):

```swift
@Published var pipelineErrors: [UUID: String] = [:]
```

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate project | `xcodegen generate` | exit 0 |
| Build | `xcodebuild -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS' build` | `BUILD SUCCEEDED` |
| Tests | `xcodebuild -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS' test` | `TEST SUCCEEDED` |

## Scope

**In scope** (the only files you should modify):
- `SynapseMeetings/Models/AppState.swift`
- `SynapseMeetingsTests/PipelineExecutionTests.swift` (extend — created by plan 003)

**Out of scope** (do NOT touch):
- `RecordingStore.swift` — no store-level versioning/locking; the MainActor
  fetch-mutate-upsert is sufficient.
- Other `AppState` write paths (`updateAttendees`, `updateLiveNotes`, `saveEdits`
  in the view) — they already write fresh values.
- UI files.

## Git workflow

- Branch: `advisor/006-pipeline-stale-snapshot-merge`
- Commits: helper + rewrite, then tests; e.g.
  `Pipeline writes only its own fields via fetch-mutate-upsert`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a fetch-mutate-upsert helper

In `AppState.swift`, near `executePipeline`:

```swift
/// Re-fetches the latest stored copy of the recording, applies `mutate` to it,
/// and upserts the result. Because AppState is @MainActor and there is no
/// suspension point inside, concurrent UI edits can never be clobbered by the
/// pipeline's long-running steps. Returns the updated value, or nil if the
/// recording was deleted mid-pipeline.
@discardableResult
private func applyPipelineUpdate(
    id: Recording.ID,
    _ mutate: (inout Recording) -> Void
) -> Recording? {
    guard var latest = store.recordings.first(where: { $0.id == id }) else { return nil }
    mutate(&latest)
    store.upsert(latest)
    return latest
}
```

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED` (helper unused yet; allow the
unused warning or proceed straight to Step 2 before building).

### Step 2: Rewrite `executePipeline` to use the helper

Restructure so that:

- Reads of inputs (transcript emptiness, audio URL, attendees for the speaker-count
  hint and summary, liveNotes, speakerTurns, calendarEventTitle) happen from a
  **freshly fetched copy at the point of use**, not the top-of-function snapshot.
- Every write goes through `applyPipelineUpdate`, mutating ONLY pipeline-owned
  fields. Examples of the target shape:

```swift
applyPipelineUpdate(id: id) { $0.status = .transcribing }
...
let asrResult = try await asrTask
let segments = await diarizeTask
applyPipelineUpdate(id: id) {
    $0.transcript = asrResult.text
    if let segments, let timings = asrResult.tokenTimings, !timings.isEmpty {
        $0.speakerTurns = Self.alignTokensToSpeakers(tokens: timings, segments: segments)
    }
}
```

and for the summarize success case:

```swift
applyPipelineUpdate(id: id) {
    $0.summaryMarkdown = combined
    if $0.calendarEventTitle == nil,
       let extracted = Self.extractTitle(from: summaryOnly), !extracted.isEmpty {
        $0.title = extracted
    }
    $0.status = .ready
}
```

Details that must survive the rewrite:

- The early-exit when the recording no longer exists: if any
  `applyPipelineUpdate` returns nil (deleted mid-pipeline), `return` — this is an
  improvement over today (currently a deleted recording gets resurrected by the
  next upsert; with the helper it stays deleted).
- The `combined` summary assembly (notes section, speaker-turn formatting, raw
  transcript appendix) must read `liveNotes`/`speakerTurns`/`transcript` from a
  fresh fetch made *after* transcription completed, so freshly typed notes are
  included rather than the stale ones. Fetch once into a local
  (`guard let current = store.recordings.first(...)`) right before building the
  Claude inputs.
- Error paths: `applyPipelineUpdate(id: id) { $0.status = .failed; $0.lastError = ... }`.
- Keep the `forceSummarize` logic (plan 001) and `makeSummarizer` seam (plan 003)
  exactly as they are.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`, and
`grep -c "store.upsert" SynapseMeetings/Models/AppState.swift` → upserts inside
`executePipeline` are gone (remaining matches are in `applyPipelineUpdate`,
`createNewNote`, `startNewRecording`, `stopRecordingAndProcess`,
`stopActiveRecordingAndProcess` area, `updateLiveNotes`, `updateAttendees`,
`forgetAttendeeEverywhere`, `resummarize`, `retry` — list them in your report).

### Step 3: Remove dead `pipelineErrors`

Delete `AppState.swift:21` (`@Published var pipelineErrors: [UUID: String] = [:]`).

**Verify**: `grep -rn "pipelineErrors" SynapseMeetings/ SynapseMeetingsTests/` → no
matches; `xcodebuild ... build` → `BUILD SUCCEEDED`.

### Step 4: Lost-update regression test

Extend `SynapseMeetingsTests/PipelineExecutionTests.swift` (from plan 003) with a
stub summarizer that parks until released, so the test can edit the recording
mid-pipeline:

```swift
private final class GatedSummarizer: Summarizing, @unchecked Sendable {
    let gate = AsyncStream<Void>.makeStream()
    func summarize(transcript: String, liveNotes: String, attendees: [String],
                   speakerLabeled: Bool, suggestedTitle: String?,
                   systemPromptOverride: String?,
                   userPromptTemplateOverride: String?) async throws -> String {
        for await _ in gate.stream { break }   // wait until the test releases us
        return "# Done\n\nSummary"
    }
    func release() { gate.continuation.yield(); gate.continuation.finish() }
}
```

Test `testEditDuringSummarize_isNotClobbered`:

1. Seed a recording with non-empty `transcript`, empty `summaryMarkdown`,
   `status: .summarizing`, no attendees.
2. Start `let pipelineTask = Task { await app.executePipeline(id: rec.id) }`.
3. `await Task.yield()` a few times (or poll until `status == .summarizing` is
   re-persisted) so the pipeline is parked inside the gated summarizer.
4. Mutate via the store as the UI would:
   `app.updateAttendees(for: rec.id, attendees: [Attendee(name: "Sarah")])`.
5. `summarizer.release()`; `await pipelineTask.value`.
6. Assert the final stored recording has BOTH `status == .ready` with the new
   summary AND `attendees.first?.name == "Sarah"`.

Also add `testDeletedDuringPipeline_staysDeleted`: park, `app.store.delete(rec)`,
release, await; assert `app.store.recordings` does not contain the id.

**Verify**: `xcodebuild ... test` → `TEST SUCCEEDED`, including the 2 new tests.
As a sanity check, the lost-update test MUST fail if you re-introduce the old
whole-struct upsert (you can verify mentally; do not actually revert).

## Test plan

Step 4's two tests, plus the plan-003 suite and all existing tests:
`xcodebuild ... test` → `TEST SUCCEEDED`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `xcodebuild ... build` → `BUILD SUCCEEDED`
- [ ] `xcodebuild ... test` → `TEST SUCCEEDED`, including
  `testEditDuringSummarize_isNotClobbered` and `testDeletedDuringPipeline_staysDeleted`
- [ ] No `store.upsert` calls remain inside `executePipeline` (manual read; paste
  the function in your report)
- [ ] `grep -rn "pipelineErrors" SynapseMeetings/` → no matches
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 003 has not landed (no seam, no `PipelineExecutionTests`) — this plan's
  tests cannot be written; do not execute it early.
- `executePipeline` has been restructured beyond plans 001/003's documented changes.
- You find an actual consumer of `pipelineErrors` (the planning-time grep found
  declaration only — re-verify before deleting).
- The rewrite seems to need changes to `RecordingStore` or view files.

## Maintenance notes

- Rule for future pipeline edits: **the pipeline never holds a `Recording` across
  an `await` and then upserts it** — always `applyPipelineUpdate`. Consider adding
  that sentence as a doc comment on `executePipeline` (in scope).
- Reviewer should scrutinize: the summarize-input fetch (notes/speaker turns must
  be the post-transcription fresh copy) and the deleted-mid-pipeline early return.
- With this plan plus 002, concurrent edit flows are closed end-to-end; if a future
  feature adds background sync, the same helper pattern applies to its writer.
