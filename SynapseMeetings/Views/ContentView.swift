import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showCommitSidebar: Bool = true
    @State private var showFirstRunSheet: Bool = false

    @AppStorage("calendarPaneHeight") private var calendarPaneHeight: Double = 380
    @State private var dragStartHeight: Double? = nil
    private let calendarMinHeight: Double = 180
    private let calendarMaxHeight: Double = 600

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            RecordingsListView()
                .navigationSplitViewColumnWidth(min: 180, ideal: 300, max: 500)
        } content: {
            if let recording = app.selectedRecording {
                RecordingDetailView(recording: recording)
                    .id(recording.id)
            } else {
                EmptyDetailView()
            }
        } detail: {
            VStack(spacing: 0) {
                CalendarSidebarView()
                    .frame(height: calendarPaneHeight)
                CalendarPaneDragHandle(
                    height: $calendarPaneHeight,
                    dragStartHeight: $dragStartHeight,
                    minHeight: calendarMinHeight,
                    maxHeight: calendarMaxHeight
                )
                Group {
                    if let recording = app.selectedRecording {
                        CommitSidebarView(recording: recording)
                    } else {
                        EmptyCommitView()
                    }
                }
                .frame(maxHeight: .infinity)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 320, max: 500)
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
            Text("Hit ⌘N for a new note, or ⌘R to record.")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}

private struct CalendarPaneDragHandle: View {
    @Binding var height: Double
    @Binding var dragStartHeight: Double?
    let minHeight: Double
    let maxHeight: Double

    @State private var isHovering = false

    var body: some View {
        ZStack {
            Divider()
            Rectangle()
                .fill(Color.clear)
                .frame(height: 6)
                .contentShape(Rectangle())
                .onHover { hovering in
                    isHovering = hovering
                    if hovering {
                        NSCursor.resizeUpDown.push()
                    } else {
                        NSCursor.pop()
                    }
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragStartHeight == nil {
                                dragStartHeight = height
                            }
                            let proposed = (dragStartHeight ?? height) + Double(value.translation.height)
                            height = min(max(proposed, minHeight), maxHeight)
                        }
                        .onEnded { _ in
                            dragStartHeight = nil
                        }
                )
        }
        .frame(height: 6)
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
