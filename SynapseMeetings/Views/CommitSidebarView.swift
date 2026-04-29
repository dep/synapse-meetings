import SwiftUI

extension Notification.Name {
    static let flushPendingEdits = Notification.Name("SynapseMeetings.flushPendingEdits")
}

struct CommitSidebarView: View {
    @EnvironmentObject var app: AppState
    let recording: Recording

    @State private var repos: [GitHubRepo] = []
    @State private var branches: [GitHubBranch] = []
    @State private var selectedRepo: String = ""
    @State private var selectedBranch: String = ""
    @State private var folder: String = "meetings"
    @State private var filename: String = ""
    @State private var commitMessage: String = ""
    @State private var filenameUserEdited: Bool = false
    @AppStorage("commit.nestInDateFolder") private var nestInDateFolder: Bool = false
    @AppStorage("commit.lastRepo") private var lastRepo: String = ""
    @AppStorage("commit.lastBranch") private var lastBranch: String = ""
    @AppStorage("commit.lastFolder") private var lastFolder: String = "meetings"

    @State private var isLoadingRepos = false
    @State private var isLoadingBranches = false
    @State private var isCommitting = false
    @State private var errorMessage: String?
    @State private var successURL: URL?

    private var canCommit: Bool {
        recording.status == .ready || recording.status == .committed
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                Divider()

                if !canCommit {
                    notReadyState
                } else if !KeychainService.shared.has(.githubPAT) {
                    needsPATState
                } else {
                    formContent
                }
            }
            .padding(16)
        }
        .frame(maxHeight: .infinity)
        .background(.background)
        .onAppear {
            resetForNewRecording()
            ensureLoadedRepos()
        }
        .onChange(of: recording.id) { _, _ in resetForNewRecording() }
        .onChange(of: recording.title) { _, _ in
            // Title likely just got smarter (Claude finished summarizing). Refresh the
            // suggested filename unless the user has typed their own.
            guard !filenameUserEdited else { return }
            filename = Self.suggestedFilename(for: recording)
            commitMessage = "Add notes: \(recording.title)"
        }
        .onReceive(NotificationCenter.default.publisher(for: .synapseKeychainChanged)) { note in
            guard let key = note.object as? String, key == KeychainKey.githubPAT.rawValue else { return }
            // PAT just changed — force a reload.
            self.repos = []
            self.errorMessage = nil
            ensureLoadedRepos(force: true)
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: "square.and.arrow.up.on.square.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Commit to GitHub")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
        }
    }

    private var notReadyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This recording isn't ready yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Once transcription and summary are done, you can commit it here.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var needsPATState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Add a GitHub PAT in Settings to enable commits.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button("Open Settings") {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
            .buttonStyle(.bordered)
        }
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            field(label: "Repository") {
                HStack(spacing: 6) {
                    Picker("", selection: $selectedRepo) {
                        if isLoadingRepos {
                            Text("Loading…").tag("")
                        } else if repos.isEmpty {
                            Text("No repos loaded").tag("")
                        } else {
                            Text("Select a repo").tag("")
                            ForEach(repos) { repo in
                                Text(repo.fullName).tag(repo.fullName)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .onChange(of: selectedRepo) { _, newValue in
                        branches = []
                        selectedBranch = ""
                        if !newValue.isEmpty {
                            loadBranches(for: newValue)
                        }
                    }
                    Button {
                        repos = []
                        errorMessage = nil
                        ensureLoadedRepos(force: true)
                    } label: {
                        if isLoadingRepos {
                            ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 14, height: 14)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderless)
                    .help("Reload repositories from GitHub")
                    .disabled(isLoadingRepos)
                }
            }

            field(label: "Branch") {
                Picker("", selection: $selectedBranch) {
                    if isLoadingBranches {
                        Text("Loading…").tag("")
                    } else if branches.isEmpty {
                        Text(selectedRepo.isEmpty ? "Pick a repo first" : "No branches").tag("")
                    } else {
                        Text("Select a branch").tag("")
                        ForEach(branches) { b in
                            Text(b.name).tag(b.name)
                        }
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(branches.isEmpty)
            }

            field(label: "Folder") {
                TextField("e.g. meetings", text: $folder)
                    .textFieldStyle(.roundedBorder)
            }

            Toggle(isOn: $nestInDateFolder) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Nest in today's folder")
                        .font(.system(size: 12))
                    Text("Adds /\(Self.dateFolderName(for: recording.createdAt)) to the path")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            field(label: "Filename") {
                TextField("e.g. 2026-04-25-standup.md", text: Binding(
                    get: { filename },
                    set: { newValue in
                        filename = newValue
                        filenameUserEdited = true
                    }
                ))
                .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("PATH PREVIEW")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Text(commitPathPreview)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }

            field(label: "Commit message") {
                TextField("Add meeting notes", text: $commitMessage)
                    .textFieldStyle(.roundedBorder)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let successURL {
                Link(destination: successURL) {
                    Label("View on GitHub", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
            }

            Button {
                performCommit()
            } label: {
                HStack {
                    if isCommitting {
                        ProgressView().controlSize(.small)
                    }
                    Text(isCommitting ? "Committing…" : "Commit & Push")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isCommitting || !readyToCommit)

            if recording.status == .committed,
               let path = recording.committedPath,
               let repo = recording.committedRepo {
                Text("Last committed to \(repo)/\(path)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var readyToCommit: Bool {
        !selectedRepo.isEmpty
            && !selectedBranch.isEmpty
            && !filename.trimmingCharacters(in: .whitespaces).isEmpty
            && !commitMessage.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var commitPath: String {
        let trimmedFolder = folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let trimmedFilename = filename.trimmingCharacters(in: .whitespaces)
        let dateSegment = nestInDateFolder ? Self.dateFolderName(for: recording.createdAt) : ""
        let segments = [trimmedFolder, dateSegment].filter { !$0.isEmpty }
        return segments.isEmpty ? trimmedFilename : "\(segments.joined(separator: "/"))/\(trimmedFilename)"
    }

    private var commitPathPreview: String {
        let path = commitPath
        return path.isEmpty ? "(filename required)" : path
    }

    static func dateFolderName(for date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// Builds a "<yyyy-MM-dd>-<hyphenated-title>.md" filename from a recording.
    static func suggestedFilename(for recording: Recording) -> String {
        let datePrefix = dateFolderName(for: recording.createdAt)
        let slug = slugify(recording.title)
        let body = slug.isEmpty ? "recording" : slug
        return "\(datePrefix)-\(body).md"
    }

    /// Lowercase, ASCII-folded, space-and-punctuation-collapsed-to-hyphens slug.
    static func slugify(_ raw: String) -> String {
        let lowered = raw.lowercased()
        let folded = lowered.folding(options: .diacriticInsensitive, locale: .current)
        var out = ""
        var lastWasHyphen = false
        for scalar in folded.unicodeScalars {
            let c = Character(scalar)
            if c.isLetter || c.isNumber {
                out.append(c)
                lastWasHyphen = false
            } else if !lastWasHyphen && !out.isEmpty {
                out.append("-")
                lastWasHyphen = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    private func field<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
            content()
        }
    }

    // MARK: - Actions

    private func resetForNewRecording() {
        errorMessage = nil
        successURL = nil
        filenameUserEdited = false

        filename = Self.suggestedFilename(for: recording)
        commitMessage = "Add notes: \(recording.title)"

        // Precedence for repo/branch/folder: this recording's prior commit > last-used > default.
        if let prior = recording.committedRepo {
            selectedRepo = prior
        } else if !lastRepo.isEmpty {
            selectedRepo = lastRepo
        }
        if let prior = recording.committedBranch {
            selectedBranch = prior
        } else if !lastBranch.isEmpty {
            selectedBranch = lastBranch
        }

        // If the recording has been committed before, prefer the exact path it landed at.
        if let path = recording.committedPath {
            let parts = path.split(separator: "/")
            if parts.count > 1 {
                folder = parts.dropLast().joined(separator: "/")
                filename = String(parts.last ?? "")
            }
        } else {
            folder = lastFolder
        }
    }

    private func ensureLoadedRepos(force: Bool = false) {
        guard KeychainService.shared.has(.githubPAT) else { return }
        guard force || (repos.isEmpty && !isLoadingRepos) else { return }
        isLoadingRepos = true
        errorMessage = nil
        Task {
            do {
                let svc = try GitHubService.makeFromKeychain()
                let r = try await svc.listRepos()
                await MainActor.run {
                    self.repos = r.sorted { $0.fullName.lowercased() < $1.fullName.lowercased() }
                    self.isLoadingRepos = false
                    if r.isEmpty {
                        self.errorMessage = "GitHub returned no repositories. Does your PAT have the `repo` scope?"
                    }
                    // If we pre-selected a repo from saved prefs, kick off branch loading now
                    // that we've confirmed it actually exists in the user's repo list.
                    if !self.selectedRepo.isEmpty,
                       self.branches.isEmpty,
                       r.contains(where: { $0.fullName == self.selectedRepo }) {
                        self.loadBranches(for: self.selectedRepo)
                    } else if !self.selectedRepo.isEmpty,
                              !r.contains(where: { $0.fullName == self.selectedRepo }) {
                        // Saved repo no longer exists for this PAT — clear it.
                        self.selectedRepo = ""
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoadingRepos = false
                }
            }
        }
    }

    private func loadBranches(for repo: String) {
        isLoadingBranches = true
        Task {
            do {
                let svc = try GitHubService.makeFromKeychain()
                let bs = try await svc.listBranches(repoFullName: repo)
                await MainActor.run {
                    self.branches = bs
                    self.isLoadingBranches = false
                    // Preserve user's pre-selected branch if it exists in this repo;
                    // otherwise fall back to the repo's default, then any branch.
                    if !self.selectedBranch.isEmpty,
                       bs.contains(where: { $0.name == self.selectedBranch }) {
                        // keep it
                    } else if let r = repos.first(where: { $0.fullName == repo }) {
                        self.selectedBranch = r.defaultBranch
                    } else if let first = bs.first {
                        self.selectedBranch = first.name
                    }
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isLoadingBranches = false
                }
            }
        }
    }

    private func performCommit() {
        errorMessage = nil
        successURL = nil
        isCommitting = true

        // Flush any unsaved edits in the note editor before committing.
        NotificationCenter.default.post(
            name: .flushPendingEdits,
            object: nil,
            userInfo: ["recordingID": recording.id]
        )
        let latest = app.store.recordings.first(where: { $0.id == recording.id }) ?? recording

        let cleanPath = commitPath
        let contents = latest.summaryMarkdown
        let message = commitMessage
        let repo = selectedRepo
        let branch = selectedBranch
        Task {
            do {
                let svc = try GitHubService.makeFromKeychain()
                let result = try await svc.commitFile(
                    repoFullName: repo,
                    branch: branch,
                    path: cleanPath,
                    contents: contents,
                    commitMessage: message
                )
                await MainActor.run {
                    self.successURL = result.htmlURL
                    self.isCommitting = false
                    var updated = app.store.recordings.first(where: { $0.id == recording.id }) ?? recording
                    updated.status = .committed
                    updated.committedRepo = repo
                    updated.committedBranch = branch
                    updated.committedPath = result.path
                    updated.committedSha = result.sha
                    updated.committedAt = Date()
                    app.store.upsert(updated)

                    // Remember these for the next commit.
                    self.lastRepo = repo
                    self.lastBranch = branch
                    self.lastFolder = self.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
                }
            } catch {
                await MainActor.run {
                    self.errorMessage = error.localizedDescription
                    self.isCommitting = false
                }
            }
        }
    }
}
