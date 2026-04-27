import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    @State private var anthropicKeyDraft: String = ""
    @State private var githubPATDraft: String = ""
    @State private var anthropicHasStored: Bool = false
    @State private var githubHasStored: Bool = false
    @State private var saveError: String?
    @State private var savedFlash: Bool = false
    @State private var globalHotkey: KeyCombo? = GlobalHotkeyService.shared.keyCombo

    private let availableModels: [String] = [
        "claude-opus-4-7",
        "claude-sonnet-4-6",
        "claude-haiku-4-5-20251001"
    ]

    var body: some View {
        TabView {
            apiKeysTab
                .tabItem { Label("API Keys", systemImage: "key.fill") }
            modelTab
                .tabItem { Label("Model", systemImage: "sparkles") }
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 360)
        .onAppear { reload() }
    }

    private var apiKeysTab: some View {
        Form {
            Section("Anthropic") {
                LabeledContent("API key") {
                    secretField(draft: $anthropicKeyDraft, hasStored: anthropicHasStored,
                                placeholder: "sk-ant-…")
                }
                Text("Used to summarize transcripts. Stored in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("GitHub") {
                LabeledContent("Personal access token") {
                    secretField(draft: $githubPATDraft, hasStored: githubHasStored,
                                placeholder: "github_pat_…")
                }
                Text("Needs `repo` scope to create commits. Stored in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let saveError {
                Text(saveError).foregroundStyle(.red).font(.caption)
            }

            HStack {
                Spacer()
                if savedFlash {
                    Label("Saved", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                        .transition(.opacity)
                }
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var modelTab: some View {
        Form {
            Section("Summarization model") {
                Picker("Model", selection: $app.anthropicModel) {
                    ForEach(availableModels, id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                .pickerStyle(.menu)
                Text("Sonnet 4.6 is a great default. Opus is smartest. Haiku is fastest and cheapest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var shortcutsTab: some View {
        Form {
            Section("Recording") {
                LabeledContent("Start / Stop recording") {
                    KeyRecorderField(keyCombo: $globalHotkey)
                }
                Text("Works system-wide, even when the app is in the background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private var aboutTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Synapse Meetings")
                .font(.title2.weight(.semibold))
            Text("Record → Transcribe → Summarize → Commit.")
                .foregroundStyle(.secondary)
            Divider().padding(.vertical, 4)
            Text("Speech model: Parakeet TDT v3 via FluidAudio (runs locally on the Apple Neural Engine).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Summarization: Anthropic API.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    @ViewBuilder
    private func secretField(draft: Binding<String>, hasStored: Bool, placeholder: String) -> some View {
        HStack {
            SecureField(hasStored ? "●●●●●●●●" : placeholder, text: draft)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            if hasStored {
                Text("stored")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func reload() {
        anthropicHasStored = KeychainService.shared.has(.anthropicAPIKey)
        githubHasStored = KeychainService.shared.has(.githubPAT)
        anthropicKeyDraft = ""
        githubPATDraft = ""
    }

    private func save() {
        saveError = nil
        do {
            let trimmedAnthropic = anthropicKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedAnthropic.isEmpty {
                try KeychainService.shared.set(trimmedAnthropic, for: .anthropicAPIKey)
            }
            let trimmedGithub = githubPATDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedGithub.isEmpty {
                try KeychainService.shared.set(trimmedGithub, for: .githubPAT)
            }
            withAnimation { savedFlash = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation { savedFlash = false }
            }
            reload()
        } catch {
            saveError = "Failed to save: \(error.localizedDescription)"
        }
    }
}
