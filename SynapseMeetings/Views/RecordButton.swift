import SwiftUI

struct RecordButton: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        if app.recorder.isRecording {
            Button {
                if let r = app.selectedRecording {
                    app.stopRecordingAndProcess(r)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "stop.fill")
                    Text(formattedElapsed(app.recorder.elapsed))
                        .monospacedDigit()
                }
                .fontWeight(.semibold)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .help("Stop recording")
        } else {
            Button {
                app.requestNewRecording()
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(.red)
                        .frame(width: 10, height: 10)
                    Text("Record")
                        .fontWeight(.semibold)
                }
            }
            .buttonStyle(.bordered)
            .help("Start recording (⌘R)")
        }
    }

    private func formattedElapsed(_ t: TimeInterval) -> String {
        let total = Int(t)
        let m = total / 60
        let s = total % 60
        return String(format: "%02d:%02d", m, s)
    }
}
