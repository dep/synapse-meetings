import SwiftUI
import EventKit

struct SettingsView: View {
    @EnvironmentObject var app: AppState

    @State private var anthropicKeyDraft: String = ""
    @State private var openRouterKeyDraft: String = ""
    @State private var githubPATDraft: String = ""
    @State private var anthropicHasStored: Bool = false
    @State private var openRouterHasStored: Bool = false
    @State private var githubHasStored: Bool = false
    @State private var saveError: String?
    @State private var savedFlash: Bool = false
    @State private var globalHotkey: KeyCombo? = GlobalHotkeyService.shared.keyCombo
    @State private var userPromptDraft: String = ""
    @State private var userPromptDebounceTask: Task<Void, Never>? = nil

    private let availableModels: [String] = [
        "claude-opus-4-7",
        "claude-sonnet-4-6",
        "claude-haiku-4-5-20251001"
    ]

    var body: some View {
        TabView {
            apiKeysTab
                .tabItem { Label("API Keys", systemImage: "key.fill") }
            aiTab
                .tabItem { Label("AI", systemImage: "sparkles") }
            audioTab
                .tabItem { Label("Audio", systemImage: "mic.fill") }
            calendarTab
                .tabItem { Label("Calendar", systemImage: "calendar") }
            shortcutsTab
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
            aboutTab
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 720, height: 620)
        .onAppear { reload() }
    }

    private var apiKeysTab: some View {
        Form {
            Section("Anthropic") {
                LabeledContent("API key") {
                    secretField(draft: $anthropicKeyDraft, hasStored: anthropicHasStored,
                                placeholder: "sk-ant-…")
                }
                Text("Used to summarize transcripts with Claude models. Stored in your macOS Keychain.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("OpenRouter") {
                LabeledContent("API key") {
                    secretField(draft: $openRouterKeyDraft, hasStored: openRouterHasStored,
                                placeholder: "sk-or-v1-…")
                }
                Text("Free alternative for summarization with multilingual models like Gemma. Stored in your macOS Keychain.")
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

    private var aiTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Provider picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("Provider")
                        .font(.headline)
                    Picker("", selection: providerBinding) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.displayName).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 320)
                    Text("Anthropic uses paid Claude models. OpenRouter offers free multilingual models — needs an OpenRouter API key.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // Model picker (per provider)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Summarization model")
                        .font(.headline)
                    HStack {
                        switch app.llmProvider {
                        case .anthropic:
                            Picker("", selection: $app.anthropicModel) {
                                ForEach(availableModels, id: \.self) { id in
                                    Text(id).tag(id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 280)
                        case .openrouter:
                            Picker("", selection: $app.openRouterModel) {
                                ForEach(OpenRouterService.curatedFreeModels, id: \.self) { id in
                                    Text(id).tag(id)
                                }
                            }
                            .labelsHidden()
                            .pickerStyle(.menu)
                            .frame(maxWidth: 320)
                        }
                        Spacer()
                    }
                    Text(modelHelpText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()

                // User prompt template editor
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("User instructions")
                            .font(.headline)
                        Spacer()
                        Button("Reset to default") {
                            userPromptDraft = AnthropicService.defaultUserPromptTemplate
                            app.anthropicUserPromptTemplate = AnthropicService.defaultUserPromptTemplate
                        }
                        .controlSize(.small)
                        .disabled(effectiveUserPromptTemplate == AnthropicService.defaultUserPromptTemplate)
                    }
                    Text("The body of the user message. Controls the summary's structure (headings, sections). The placeholders below are substituted at runtime — keep them in your template.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    placeholderLegend
                        .padding(.top, 2)

                    TextEditor(text: $userPromptDraft)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 280, maxHeight: 380)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .stroke(Color.secondary.opacity(0.3), lineWidth: 0.5)
                        )
                        .onChange(of: userPromptDraft) { newValue in
                            userPromptDebounceTask?.cancel()
                            userPromptDebounceTask = Task {
                                try? await Task.sleep(nanoseconds: 500_000_000)
                                guard !Task.isCancelled else { return }
                                app.anthropicUserPromptTemplate = newValue
                            }
                        }
                }
            }
            .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var placeholderLegend: some View {
        HStack(spacing: 6) {
            ForEach([
                "{{ATTENDEES_BLOCK}}",
                "{{SPEAKERS_BLOCK}}",
                "{{NOTES_BLOCK}}",
                "{{TRANSCRIPT}}"
            ], id: \.self) { token in
                Text(token)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(Color.secondary.opacity(0.15))
                    )
            }
        }
    }

    private var providerBinding: Binding<LLMProvider> {
        Binding(
            get: { app.llmProvider },
            set: { app.llmProvider = $0 }
        )
    }

    private var modelHelpText: String {
        switch app.llmProvider {
        case .anthropic:
            return "Sonnet 4.6 is a great default. Opus is smartest. Haiku is fastest and cheapest."
        case .openrouter:
            return "Free models. Gemma 4 31B is the recommended default — best multilingual coverage for English, Spanish, and Portuguese."
        }
    }

    private var effectiveUserPromptTemplate: String {
        let trimmed = userPromptDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? AnthropicService.defaultUserPromptTemplate : userPromptDraft
    }

    private var audioTab: some View {
        Form {
            Section("Recording input") {
                Picker("Input device", selection: $app.audioInputDeviceUID) {
                    Text("System default").tag("")
                    if !app.audioDevices.inputDevices.isEmpty {
                        Divider()
                        ForEach(app.audioDevices.inputDevices, id: \.uid) { device in
                            Text(audioDeviceLabel(for: device)).tag(device.uid)
                        }
                    }
                }
                .pickerStyle(.menu)

                if !app.audioInputDeviceUID.isEmpty,
                   app.audioDevices.device(forUID: app.audioInputDeviceUID) == nil {
                    Label(
                        "The previously selected device isn't connected. Recording will use the system default until it's reconnected.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                }

                Text("Pick a virtual mixer (e.g. BlackHole, Loopback) to capture meeting audio + your mic together.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Spacer()
                    Button("Refresh devices") {
                        app.audioDevices.refresh()
                    }
                    .controlSize(.small)
                }
            }

            Section("Speaker diarization") {
                Toggle("Identify individual speakers", isOn: $app.diarizationEnabled)
                Text("Runs a separate speaker model after transcription so the saved transcript and summary attribute lines to Speaker 1, Speaker 2, etc. The model downloads once on first use (~25 MB).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func audioDeviceLabel(for device: InputDevice) -> String {
        let channels = device.inputChannelCount == 1 ? "1 ch" : "\(device.inputChannelCount) ch"
        if device.manufacturer.isEmpty {
            return "\(device.name) — \(channels)"
        }
        return "\(device.name) — \(channels)"
    }

    private var calendarTab: some View {
        Form {
            switch app.calendar.authState {
            case .granted:
                Section("Show events from") {
                    if app.calendar.calendars.isEmpty {
                        Text("No calendars found.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(groupedCalendars(), id: \.source) { group in
                            ForEach(group.calendars, id: \.calendarIdentifier) { cal in
                                CalendarToggleRow(
                                    calendar: cal,
                                    sourceLabel: group.source,
                                    isOn: visibilityBinding(for: cal)
                                )
                            }
                        }
                    }
                }

                Section("Recording from events") {
                    Toggle("Pre-fill attendees from calendar events", isOn: $app.prefillAttendeesFromCalendar)
                    Text("When you start recording from an event row, the event's attendees become checked attendees on the recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            case .notDetermined:
                Section("Calendar access") {
                    Text("Synapse Meetings hasn't asked for calendar access yet.")
                        .font(.callout)
                    Button("Request Calendar Access") {
                        Task { await app.calendar.requestAccess() }
                    }
                }
            case .denied, .restricted:
                Section("Calendar access") {
                    Text("Calendar access is currently disabled. Enable it in System Settings → Privacy & Security → Calendars.")
                        .font(.callout)
                    Button("Open System Settings") {
                        app.calendar.openSystemSettings()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private struct CalendarGroup {
        let source: String
        let calendars: [EKCalendar]
    }

    private func groupedCalendars() -> [CalendarGroup] {
        let bySource = Dictionary(grouping: app.calendar.calendars) { $0.source.title }
        return bySource
            .map { CalendarGroup(source: $0.key, calendars: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.source < $1.source }
    }

    private func visibilityBinding(for cal: EKCalendar) -> Binding<Bool> {
        Binding(
            get: { app.calendar.isVisible(cal) },
            set: { app.calendar.setVisible(cal, visible: $0) }
        )
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

            if GlobalHotkeyService.shared.needsAccessibilityPermission {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Accessibility access required for global shortcut", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.orange)
                        Text("The shortcut only fires when Synapse Meetings is in the foreground until you grant Accessibility access. macOS requires this to listen for keys while another app is active.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button("Grant Accessibility Access…") {
                            GlobalHotkeyService.shared.requestAccessibilityPermissionIfNeeded()
                        }
                        .buttonStyle(.bordered)
                    }
                    .padding(.vertical, 4)
                }
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
            Text("Summarization: Anthropic API or OpenRouter (free multilingual models).")
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
        openRouterHasStored = KeychainService.shared.has(.openRouterAPIKey)
        githubHasStored = KeychainService.shared.has(.githubPAT)
        anthropicKeyDraft = ""
        openRouterKeyDraft = ""
        githubPATDraft = ""
        userPromptDraft = app.anthropicUserPromptTemplate.isEmpty
            ? AnthropicService.defaultUserPromptTemplate
            : app.anthropicUserPromptTemplate
    }

    private func save() {
        saveError = nil
        do {
            let trimmedAnthropic = anthropicKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedAnthropic.isEmpty {
                try KeychainService.shared.set(trimmedAnthropic, for: .anthropicAPIKey)
            }
            let trimmedOpenRouter = openRouterKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedOpenRouter.isEmpty {
                try KeychainService.shared.set(trimmedOpenRouter, for: .openRouterAPIKey)
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

private struct CalendarToggleRow: View {
    let calendar: EKCalendar
    let sourceLabel: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 8) {
                Circle()
                    .fill(Color(cgColor: calendar.cgColor))
                    .frame(width: 10, height: 10)
                Text(calendar.title)
                Spacer()
                Text(sourceLabel)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }
}
