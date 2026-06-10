# Plan 002: Autosave manual summary edits so switching rows or quitting never loses them

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat c234ef6..HEAD -- SynapseMeetings/Views/RecordingDetailView.swift`
> If the file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (001 recommended first — both touch the resummarize flow's surroundings)
- **Category**: bug
- **Planned at**: commit `c234ef6`, 2026-06-10

## Why this matters

Edits to a recording's summary live only in a SwiftUI `@State` string
(`editedMarkdown`) behind a manual "Save" button. `ContentView` applies
`.id(recording.id)` to the detail view, so **selecting another recording destroys
the view state and silently discards unsaved edits**. Quitting the app does the
same. Meanwhile the live-notes editor in the same app autosaves on every keystroke,
and the user-prompt editor in Settings autosaves with a 0.5s debounce — so users
have been trained to expect autosave. This plan makes the summary editor autosave
with the same debounce pattern, keeping the Save button as an instant flush.

## Current state

Relevant files:

- `SynapseMeetings/Views/RecordingDetailView.swift` — the summary editor. The only
  file you will modify.
- `SynapseMeetings/Views/ContentView.swift:19-21` — read-only context; shows why
  state is lost on selection change:

```swift
if let recording = app.activeRecording ?? app.selectedRecording {
    RecordingDetailView(recording: recording)
        .id(recording.id)
```

- `SynapseMeetings/Views/SettingsView.swift:140-147` — the repo's debounce
  exemplar. **Match this pattern**:

```swift
.onChange(of: userPromptDraft) { newValue in
    userPromptDebounceTask?.cancel()
    userPromptDebounceTask = Task {
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard !Task.isCancelled else { return }
        app.anthropicUserPromptTemplate = newValue
    }
}
```

The editor state and save path today, `RecordingDetailView.swift`:

```swift
// line 8
@State private var editedMarkdown: String = ""

// lines 58-67 — manual Save button
if recording.status == .ready || recording.status == .committed {
    Button {
        saveEdits()
    } label: {
        Label("Save", systemImage: "checkmark.circle")
            .font(.caption)
    }
    .buttonStyle(.bordered)
    .disabled(editedMarkdown == recording.summaryMarkdown)
}

// lines 27-38 — pipeline refresh + flush listener
.onChange(of: recording.summaryMarkdown) { _, _ in
    // If pipeline updates the summary, refresh the editor
    if recording.summaryMarkdown != editedMarkdown {
        editedMarkdown = recording.summaryMarkdown
    }
}
.onReceive(NotificationCenter.default.publisher(for: .flushPendingEdits)) { note in
    guard let id = note.userInfo?["recordingID"] as? UUID, id == recording.id else { return }
    if editedMarkdown != recording.summaryMarkdown {
        saveEdits()
    }
}

// lines 177-184
private func saveEdits() {
    var updated = recording
    updated.summaryMarkdown = editedMarkdown
    if let title = AppState.extractTitle(from: editedMarkdown) {
        updated.title = title
    }
    app.store.upsert(updated)
}
```

The editor text field itself is `SearchableTextEditor(text: $editedMarkdown, ...)`
inside the `editor` computed property (lines 111-139), shown only for
`.ready`/`.committed` status. `.flushPendingEdits` is posted by
`CommitSidebarView.swift:428` (before commit) and `AppState.resummarize`
(before a note-only re-summarize).

Important interaction: `onChange(of: recording.summaryMarkdown)` (line 27) overwrites
`editedMarkdown` whenever the store's copy changes. Because debounced saves write
through `saveEdits()` → `store.upsert`, the store copy becomes equal to
`editedMarkdown`, so the guard `recording.summaryMarkdown != editedMarkdown` makes
that refresh a no-op for our own saves. No feedback loop — but verify this reasoning
holds when you implement (see STOP conditions).

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate project | `xcodegen generate` | exit 0 |
| Build | `xcodebuild -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS' build` | `BUILD SUCCEEDED` |
| Tests | `xcodebuild -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS' test` | `TEST SUCCEEDED` |

## Scope

**In scope** (the only files you should modify):
- `SynapseMeetings/Views/RecordingDetailView.swift`

**Out of scope** (do NOT touch, even though they look related):
- `SynapseMeetings/Views/ContentView.swift` — removing `.id(recording.id)` would
  change view-identity semantics across the whole detail pane; autosave makes it
  unnecessary.
- `SynapseMeetings/Views/SearchableTextEditor.swift` — the NSTextView wrapper is
  not at fault.
- `SynapseMeetings/Models/AppState.swift` — plans 001/006 own changes there.
- The live-notes editor (`RecordingInProgressView`) — already autosaves.

## Git workflow

- Branch: `advisor/002-autosave-summary-edits`
- Single commit, e.g. `Autosave summary edits with debounce; flush on view teardown`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add a debounced autosave on `editedMarkdown` changes

In `RecordingDetailView`:

1. Add state alongside `editedMarkdown` (line ~8):

```swift
@State private var autosaveTask: Task<Void, Never>? = nil
```

2. On the outer `VStack` in `body` (after the existing `.onReceive` at line ~33),
   add a debounced autosave matching the SettingsView exemplar:

```swift
.onChange(of: editedMarkdown) { _, newValue in
    guard didLoadInitial else { return }
    guard newValue != recording.summaryMarkdown else { return }
    autosaveTask?.cancel()
    autosaveTask = Task {
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard !Task.isCancelled else { return }
        saveEdits()
    }
}
```

The `didLoadInitial` guard prevents saving during the initial `loadEdits()`
population. Note: `RecordingDetailView.editor` already has an
`.onChange(of: editedMarkdown)` (line ~129) used for find-state recompute — SwiftUI
allows multiple `onChange` modifiers for the same value; leave that one alone and
attach this new one at the `body` level.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`

### Step 2: Flush pending edits on view teardown

Add to the same outer `VStack` modifier chain:

```swift
.onDisappear {
    autosaveTask?.cancel()
    if didLoadInitial, editedMarkdown != recording.summaryMarkdown {
        saveEdits()
    }
}
```

Because `ContentView` uses `.id(recording.id)`, switching rows tears the view down
and `onDisappear` fires — this is the row-switch flush. It also fires on window
close.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`

### Step 3: Keep the Save button as an instant flush

No code change required — `saveEdits()` already does this and the `.disabled`
condition already greys it out once autosave catches up. Read the button code and
confirm. (Do not remove the button: it doubles as a visible "saved" indicator —
disabled means saved.)

**Verify**: `grep -n "saveEdits()" SynapseMeetings/Views/RecordingDetailView.swift`
→ 4 matches (button, flush listener, autosave task, onDisappear).

## Test plan

This is SwiftUI view behavior with no view-testing infrastructure in the repo
(no ViewInspector, no UI test target) — automated tests are not expected for this
plan. Required verification instead:

- Full suite still green: `xcodebuild ... test` → `TEST SUCCEEDED`.
- Manual smoke (if you are able to launch the app; otherwise note it for the
  reviewer): edit a ready recording's summary, switch to another recording within
  0.5s, switch back → the edit is present.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `xcodebuild ... build` → `BUILD SUCCEEDED`
- [ ] `xcodebuild ... test` → `TEST SUCCEEDED`
- [ ] `grep -c "autosaveTask" SynapseMeetings/Views/RecordingDetailView.swift` → ≥4
- [ ] `grep -n "onDisappear" SynapseMeetings/Views/RecordingDetailView.swift` → 1 match
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The excerpts above don't match the live file (drift).
- You observe (or can construct) a feedback loop between the new
  `.onChange(of: editedMarkdown)` autosave and the existing
  `.onChange(of: recording.summaryMarkdown)` refresh — i.e. a save triggering a
  refresh triggering a save with different content. The equality guards should
  prevent this; if they don't, stop.
- The fix seems to require touching `ContentView.swift` or `AppState.swift`.

## Maintenance notes

- If plan 006 (pipeline stale-snapshot merge) lands, the pipeline will no longer be
  able to clobber a just-autosaved edit — these two plans jointly close the lost-
  update window.
- Reviewer should scrutinize: `extractTitle` runs on every autosave, so the row
  title now live-updates while typing the H1. That's a behavior change (previously
  only on manual Save) — intended, but worth a look.
- Deferred: an explicit "Saved" toast/indicator beyond the disabled Save button.
