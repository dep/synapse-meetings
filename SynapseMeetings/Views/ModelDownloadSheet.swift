import SwiftUI

struct ModelDownloadSheet: View {
    @EnvironmentObject var app: AppState
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 36, weight: .light))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Setting up Parakeet")
                        .font(.title3.weight(.semibold))
                    Text("Downloading the on-device speech model from Hugging Face. One-time setup.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            stateView

            HStack {
                Spacer()
                if case .ready = app.transcriber.modelState {
                    Button("Continue") { isPresented = false }
                        .keyboardShortcut(.defaultAction)
                } else if case .failed = app.transcriber.modelState {
                    Button("Retry") {
                        Task { try? await app.transcriber.ensureLoaded() }
                    }
                    .keyboardShortcut(.defaultAction)
                    Button("Close") { isPresented = false }
                } else {
                    Button("Hide") { isPresented = false }
                }
            }
        }
        .padding(24)
        .frame(width: 480)
        .onChange(of: app.transcriber.modelState) { _, newState in
            if case .ready = newState {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    isPresented = false
                }
            }
        }
    }

    @ViewBuilder
    private var stateView: some View {
        switch app.transcriber.modelState {
        case .notLoaded:
            ProgressView("Preparing…").frame(maxWidth: .infinity)
        case .checking:
            ProgressView("Checking for cached model…").frame(maxWidth: .infinity)
        case .downloading(let progress, let message):
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: progress) {
                    Text(message).font(.callout)
                }
                Text("\(Int(progress * 100))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        case .compiling(let message):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(message).font(.callout)
                }
                Text("This step compiles the model for the Apple Neural Engine and only happens once per machine.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        case .ready:
            Label("Speech model ready ✨", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
        case .failed(let err):
            VStack(alignment: .leading, spacing: 6) {
                Label("Setup failed", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(err)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
