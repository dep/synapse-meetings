import SwiftUI

struct RecordButton: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Group {
            if app.recorder.isRecording {
                Button {
                    if let r = app.selectedRecording {
                        app.stopRecordingAndProcess(r)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 10, height: 10)
                            .overlay(
                                Circle().stroke(.red.opacity(0.5), lineWidth: 6)
                                    .scaleEffect(1.3)
                                    .opacity(0.6)
                            )
                        Text(formattedElapsed(app.recorder.elapsed))
                            .monospacedDigit()
                            .font(.system(size: 13, weight: .semibold))
                        Text("Stop")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            } else {
                Button {
                    app.requestNewRecording()
                } label: {
                    Label("Record", systemImage: "record.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(.accentColor)
                .keyboardShortcut("n", modifiers: [.command])
            }
        }
    }

    private func formattedElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
