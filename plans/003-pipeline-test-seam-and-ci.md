# Plan 003: Make the pipeline unit-testable (service seam) and add CI that runs the tests

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat c234ef6..HEAD -- SynapseMeetings/Models/AppState.swift SynapseMeetings/Services/AnthropicService.swift SynapseMeetingsTests/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: LOW
- **Depends on**: plans/001-preserve-summary-on-failed-resummarize.md (its regression test is written here)
- **Category**: tests
- **Planned at**: commit `c234ef6`, 2026-06-10

## Why this matters

The riskiest code in this app — the transcribe→summarize state machine in
`AppState.executePipeline` — has zero test coverage, because `AppState` hard-wires
its dependencies: `AnthropicService.makeFromKeychain()` is called inline (reads the
real Keychain, hits the real network) and the store defaults to the user's real
`~/Library/Application Support` folder. On top of that, **no CI exists** (`.github/`
is absent), so even the existing tests only run when someone remembers. This plan
adds (a) a summarizer injection seam, (b) a test-mode guard so the hosted test app
doesn't request permissions or download a 470 MB model in CI, (c) pipeline unit
tests including the plan-001 regression, and (d) a GitHub Actions workflow.

## Current state

Relevant files:

- `SynapseMeetings/Models/AppState.swift` — `@MainActor final class AppState`; owns
  the pipeline. Gets the seam.
- `SynapseMeetings/Services/AnthropicService.swift` — struct with
  `func summarize(...) async throws -> String`; gets a protocol conformance.
- `SynapseMeetings/SynapseMeetingsApp.swift` — app entry; constructs `AppState()`.
- `SynapseMeetings/Models/RecordingStore.swift` — already has an injectable
  `init(baseDirectory: URL)` used by `RecordingStoreTests`. The convenience `init()`
  uses the real Application Support directory.
- `SynapseMeetingsTests/` — existing XCTest files (`AppStatePipelineTests`,
  `RecordingStoreTests`, `RecordingModelTests`, `AnthropicPromptTests`); tests run
  hosted in the app (`TEST_HOST` is set in `project.yml:94`), and use
  `@testable import Synapse_Meetings`.

Hard-wired service construction, `AppState.swift:407`:

```swift
let anthropic = try AnthropicService.makeFromKeychain(model: anthropicModel)
```

`AnthropicService.summarize` signature, `AnthropicService.swift:48-56`:

```swift
func summarize(
    transcript: String,
    liveNotes: String = "",
    attendees: [String] = [],
    speakerLabeled: Bool = false,
    suggestedTitle: String?,
    systemPromptOverride: String? = nil,
    userPromptTemplateOverride: String? = nil
) async throws -> String
```

Launch side effects that will sabotage hosted tests in CI — `AppState.init()`
(`AppState.swift:46-91`) requests microphone + calendar permission and pre-warms the
diarizer; `ContentView.onAppear` (`ContentView.swift:59-68`) kicks off
`transcriber.ensureLoaded()`, which **downloads ~470 MB of Core ML models** when
absent; `SynapseMeetingsApp` (`SynapseMeetingsApp.swift:5-11`) runs
`AppMigration.runIfNeeded()` and constructs a Sparkle `UpdaterController` (Sparkle
may show a first-run "check automatically?" prompt). Excerpt of the init tasks:

```swift
// AppState.swift:73-90
Task { [weak self] in
    await self?.recorder.requestMicrophonePermissionIfNeeded()
}
Task { [weak self] in
    await self?.calendar.requestAccess()
}
Task { [weak self] in
    guard let self else { return }
    if self.diarizationEnabled {
        try? await self.diarizer.ensureLoaded()
    }
}
```

Pipeline entry points (`AppState.swift:353-360`):

```swift
private func runPipeline(for id: Recording.ID) { ... }
private func executePipeline(id: Recording.ID) async {
    guard var recording = store.recordings.first(where: { $0.id == id }) else { return }
    ...
}
```

(If plan 001 has landed, these carry an extra `forceSummarize: Bool = false`
parameter — keep it.)

Store membership: `AppState.swift:8` → `let store = RecordingStore()`.

Conventions: plain XCTest, `@MainActor` test classes where needed (see
`AppStatePipelineTests.swift:5-6`), temp-directory stores per test (see
`RecordingStoreTests` pattern), no mocking framework — hand-rolled stubs.

## Commands you will need

| Purpose | Command | Expected on success |
|---------|---------|---------------------|
| Generate project | `xcodegen generate` | exit 0 |
| Build | `xcodebuild -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS' build` | `BUILD SUCCEEDED` |
| Tests | `xcodebuild -project SynapseMeetings.xcodeproj -scheme SynapseMeetings -destination 'platform=macOS' test` | `TEST SUCCEEDED` |
| Validate workflow syntax (optional) | `gh workflow list` after push | workflow listed |

## Scope

**In scope** (the only files you should modify/create):
- `SynapseMeetings/Models/AppState.swift` (seam + test-mode guard)
- `SynapseMeetings/Services/AnthropicService.swift` (protocol conformance only)
- `SynapseMeetings/Services/TestEnvironment.swift` (create — tiny helper)
- `SynapseMeetings/Views/ContentView.swift` (guard the model-load kick-off)
- `SynapseMeetingsTests/AppStatePipelineTests.swift` (new pipeline tests) or a new
  `SynapseMeetingsTests/PipelineExecutionTests.swift`
- `.github/workflows/ci.yml` (create)

**Out of scope** (do NOT touch):
- `SynapseMeetings/Services/TranscriptionService.swift` / `DiarizationService.swift`
  — transcription seam is NOT needed: pipeline tests below use recordings whose
  `transcript` is already non-empty, which skips the transcription step entirely.
- `project.yml` `TEST_HOST` configuration — keep hosted tests; the test-mode guard
  makes hosting safe.
- `AppMigration.swift`, `UpdaterController.swift` — migration is idempotent and
  Sparkle prompts don't block `xcodebuild test` (it runs the host app headlessly);
  only revisit if CI proves otherwise (see STOP conditions).
- Release/signing pipeline (`.agents/commands/EXPORT-SIGNED-APP.md`).

## Git workflow

- Branch: `advisor/003-pipeline-test-seam-and-ci`
- Commit per step (seam / guard / tests / CI), messages like
  `Add summarizer seam to AppState for testability`
- Do NOT push or open a PR unless the operator instructed it. (Note: the CI
  workflow only demonstrably runs after a push — see Done criteria for the local
  alternative.)

## Steps

### Step 1: Add a `Summarizing` protocol and conform `AnthropicService`

In `AnthropicService.swift`, above the struct:

```swift
/// Seam for tests: anything that can turn a transcript into summary markdown.
protocol Summarizing {
    func summarize(
        transcript: String,
        liveNotes: String,
        attendees: [String],
        speakerLabeled: Bool,
        suggestedTitle: String?,
        systemPromptOverride: String?,
        userPromptTemplateOverride: String?
    ) async throws -> String
}

extension AnthropicService: Summarizing {}
```

The existing method's defaulted parameters satisfy the protocol requirement as-is
(same names, types, and order) — if the compiler disagrees, add an explicit
forwarding method in the extension rather than touching the original.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`

### Step 2: Inject the summarizer factory and store into `AppState`

In `AppState.swift`:

1. Change the store property and add a factory property + init parameters:

```swift
let store: RecordingStore
/// Factory seam: tests replace this to avoid Keychain + network.
private let makeSummarizer: (String) throws -> any Summarizing

init(
    store: RecordingStore = RecordingStore(),
    makeSummarizer: @escaping (String) throws -> any Summarizing = { model in
        try AnthropicService.makeFromKeychain(model: model)
    }
) {
    self.store = store
    self.makeSummarizer = makeSummarizer
    // ... existing init body unchanged below ...
}
```

2. Replace `AppState.swift:407`:

```swift
let anthropic = try makeSummarizer(anthropicModel)
```

   and update the call site to pass all arguments explicitly (protocol methods
   have no default arguments):

```swift
let summaryOnly = try await anthropic.summarize(
    transcript: transcriptForClaude,
    liveNotes: recording.liveNotes,
    attendees: selectedAttendees,
    speakerLabeled: !recording.speakerTurns.isEmpty,
    suggestedTitle: nil,
    systemPromptOverride: anthropicSystemPrompt,
    userPromptTemplateOverride: anthropicUserPromptTemplate
)
```

3. Change `executePipeline` from `private` to internal and mark it
   `@discardableResult`-free, so tests can `await` it directly:

```swift
func executePipeline(id: Recording.ID, forceSummarize: Bool = false) async
```

   (`runPipeline` stays private.)

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`

### Step 3: Add a test-mode guard for launch side effects

Create `SynapseMeetings/Services/TestEnvironment.swift`:

```swift
import Foundation

enum TestEnvironment {
    /// True when running inside an XCTest host. Used to suppress launch side
    /// effects (permission prompts, model downloads) during unit tests.
    static let isRunningTests: Bool =
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        || NSClassFromString("XCTestCase") != nil
}
```

Guard the three `Task { ... }` blocks in `AppState.init` (mic permission, calendar
access, diarizer pre-warm) with:

```swift
if !TestEnvironment.isRunningTests {
    // existing three Task blocks
}
```

Guard the model-load kick-off in `ContentView.onAppear` (`ContentView.swift:59-68`)
the same way — wrap the whole `if case .notLoaded = ...` block in
`if !TestEnvironment.isRunningTests { ... }`.

**Verify**: `xcodebuild ... build` → `BUILD SUCCEEDED`, then
`xcodebuild ... test` → `TEST SUCCEEDED` (existing tests, now with guards active).

### Step 4: Write the pipeline tests

Create `SynapseMeetingsTests/PipelineExecutionTests.swift`. Pattern: temp-dir store
(model after `RecordingStoreTests`), stub summarizer, `@MainActor` test class,
`await app.executePipeline(...)` directly. Skeleton:

```swift
import XCTest
@testable import Synapse_Meetings

@MainActor
final class PipelineExecutionTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() async throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelineTests-\(UUID().uuidString)")
    }
    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private struct StubSummarizer: Summarizing {
        var result: Result<String, Error>
        func summarize(transcript: String, liveNotes: String, attendees: [String],
                       speakerLabeled: Bool, suggestedTitle: String?,
                       systemPromptOverride: String?,
                       userPromptTemplateOverride: String?) async throws -> String {
            try result.get()
        }
    }

    private func makeApp(summary: Result<String, Error>) -> AppState {
        AppState(
            store: RecordingStore(baseDirectory: tempDir),
            makeSummarizer: { _ in StubSummarizer(result: summary) }
        )
    }
    // tests below…
}
```

Required test cases (each seeds a `Recording` with non-empty `transcript` and
`status: .summarizing` via `app.store.upsert`, then awaits `executePipeline`):

1. `testSummarizeSuccess_setsSummaryAndReady` — stub returns `"# New Title\n\nBody"`;
   assert final `status == .ready`, `summaryMarkdown` contains `"# New Title"` and
   `"## Raw transcript"`, and `title == "New Title"` (extraction path, since
   `calendarEventTitle` is nil).
2. `testSummarizeFailure_setsFailedAndKeepsError` — stub throws; assert
   `status == .failed` and `lastError` has the `"Summarization failed:"` prefix.
3. **Plan-001 regression**: `testForcedResummarizeFailure_preservesOldSummary` —
   seed `summaryMarkdown = "# Old\n\nPrecious edits"`, stub throws, call
   `executePipeline(id: rec.id, forceSummarize: true)`; assert
   `summaryMarkdown == "# Old\n\nPrecious edits"` still, and `status == .failed`.
   (If plan 001 has NOT landed yet, this test cannot exist — see STOP conditions.)
4. `testNonEmptySummaryWithoutForce_skipsSummarizerAndLandsReady` — seed a non-empty
   summary, stub would throw if called; assert `status == .ready` and stub untouched
   (use a stub that records invocation in a class-box and assert it stayed false).
5. `testCalendarTitlePreserved` — seed `calendarEventTitle = "Standup"`,
   stub returns `"# AI Title\n\nBody"`; assert `title` did NOT change to `"AI Title"`.

**Verify**: `xcodebuild ... test` → `TEST SUCCEEDED`, including 5 new tests.

### Step 5: Add the GitHub Actions workflow

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    runs-on: macos-15
    timeout-minutes: 30
    steps:
      - uses: actions/checkout@v4
      - name: Install XcodeGen
        run: brew install xcodegen
      - name: Generate project
        run: xcodegen generate
      - name: Build and test
        run: |
          set -o pipefail
          xcodebuild \
            -project SynapseMeetings.xcodeproj \
            -scheme SynapseMeetings \
            -destination 'platform=macOS' \
            test
```

Notes for the executor: code signing is already disabled in `project.yml`
(`CODE_SIGNING_ALLOWED: NO`), so no signing setup is needed. SPM resolves
FluidAudio + Sparkle during the build. The test-mode guard from Step 3 is what
keeps the hosted app from prompting for permissions or downloading models on the
runner.

**Verify** (local stand-in for CI): run the exact command from the workflow's last
step locally → `TEST SUCCEEDED`. Also `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/ci.yml'))"` → exit 0 (or any YAML validity check available).

## Test plan

Covered by Step 4 (five new pipeline tests). Existing 4 test files must stay green.
Total suite: `xcodebuild ... test` → `TEST SUCCEEDED`.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `xcodebuild ... test` → `TEST SUCCEEDED`, ≥5 new tests in `PipelineExecutionTests`
- [ ] `grep -n "makeFromKeychain" SynapseMeetings/Models/AppState.swift` → no matches
  (only the default closure in `init` may reference it — adjust grep expectation:
  exactly 1 match, inside the `init` default parameter)
- [ ] `grep -rn "isRunningTests" SynapseMeetings/ | wc -l` → ≥3 (definition + 2 guards)
- [ ] `.github/workflows/ci.yml` exists and parses as YAML
- [ ] `git status` shows no modified files outside the in-scope list
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 001 has not landed (no `forceSummarize` parameter exists): write tests 1, 2,
  4, 5 only, note test 3 as blocked in `plans/README.md`, and report.
- The protocol conformance in Step 1 forces signature changes to
  `AnthropicService.summarize` itself (callers elsewhere would break).
- Hosted tests hang locally after Step 3 (a launch side effect not covered by the
  guard — e.g. Sparkle). Report which subsystem blocked rather than adding guards
  beyond the listed files.
- `AppState`'s init refactor conflicts with drift from another plan's changes.

## Maintenance notes

- Future plans 004–006 rely on this harness: 006's lost-update test injects a stub
  summarizer that parks on a continuation. Keep `executePipeline` internal and
  awaitable.
- Reviewer should scrutinize: the `init` default arguments (production behavior must
  be byte-for-byte identical — default store, default Keychain-backed factory), and
  that `TestEnvironment.isRunningTests` can never be true in a shipped build (it
  keys off XCTest-only signals).
- Deferred deliberately: a transcription seam (needs audio fixtures; only add when
  a plan actually tests the transcription branch), CI caching of SPM checkouts
  (add `actions/cache` keyed on `Package.resolved` later if CI is slow).
