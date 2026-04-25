import SwiftUI

struct ModelStatusBadge: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        switch app.transcriber.modelState {
        case .ready:
            badge(systemImage: "waveform.badge.checkmark",
                  text: "Parakeet ready",
                  tint: .green,
                  showSpinner: false)
        case .checking:
            badge(systemImage: "magnifyingglass",
                  text: "Checking model…",
                  tint: .secondary,
                  showSpinner: true)
        case .compiling(let message):
            badge(systemImage: "cpu",
                  text: message,
                  tint: .blue,
                  showSpinner: true)
        case .downloading(let progress, _):
            badge(systemImage: "arrow.down.circle",
                  text: "Downloading model — \(Int(progress * 100))%",
                  tint: .blue,
                  showSpinner: true)
        case .failed(let err):
            badge(systemImage: "exclamationmark.triangle.fill",
                  text: "Model error",
                  tint: .orange,
                  showSpinner: false)
                .help(err)
        case .notLoaded:
            EmptyView()
        }
    }

    @ViewBuilder
    private func badge(systemImage: String, text: String, tint: Color, showSpinner: Bool) -> some View {
        HStack(spacing: 5) {
            if showSpinner {
                ProgressView().controlSize(.mini).scaleEffect(0.7).frame(width: 12, height: 12)
            } else {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .fixedSize()
    }
}
