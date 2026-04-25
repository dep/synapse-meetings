import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showCommitSidebar: Bool = true
    @State private var showFirstRunSheet: Bool = false

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            RecordingsListView()
                .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
        } content: {
            if let recording = app.selectedRecording {
                RecordingDetailView(recording: recording)
                    .id(recording.id)
            } else {
                EmptyDetailView()
            }
        } detail: {
            if let recording = app.selectedRecording {
                CommitSidebarView(recording: recording)
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            } else {
                EmptyCommitView()
                    .frame(minWidth: 280, idealWidth: 320, maxWidth: 380)
            }
        }
        .navigationTitle("Synapse Meetings")
        .toolbar {
            ToolbarItem(placement: .principal) {
                ModelStatusBadge()
            }
            ToolbarItem(placement: .primaryAction) {
                RecordButton()
            }
        }
        .sheet(isPresented: $showFirstRunSheet) {
            ModelDownloadSheet(isPresented: $showFirstRunSheet)
                .environmentObject(app)
        }
        .onAppear {
            // Kick off the model load. Show the noisy first-run sheet only if
            // we're actually about to download — otherwise just load silently
            // and the toolbar badge will reflect "Loading…".
            if case .notLoaded = app.transcriber.modelState {
                if !app.transcriber.hasLocalModels {
                    showFirstRunSheet = true
                }
                Task { try? await app.transcriber.ensureLoaded() }
            }
        }
        .onChange(of: app.transcriber.modelState) { _, newState in
            // If we discover during loading that we actually need to download,
            // surface the sheet retroactively.
            if case .downloading = newState, !showFirstRunSheet {
                showFirstRunSheet = true
            }
        }
        .onReceive(app.$newRecordingRequest) { request in
            guard request != nil else { return }
            do {
                _ = try app.startNewRecording()
            } catch {
                print("Failed to start recording: \(error)")
            }
        }
    }
}

private struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "waveform")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.secondary)
            Text("No recording selected")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Hit ⌘N to record a new one.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

private struct EmptyCommitView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up.on.square")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text("Commit panel")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("Select a recording to commit it to GitHub.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.tertiary)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
