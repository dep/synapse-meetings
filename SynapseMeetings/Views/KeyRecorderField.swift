import SwiftUI
import AppKit

/// A button-like control that, when clicked, enters "recording" mode and
/// captures the next key+modifier combo the user presses.
struct KeyRecorderField: View {
    @Binding var keyCombo: KeyCombo?
    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 8) {
            Button {
                isRecording ? stopRecording() : startRecording()
            } label: {
                Text(label)
                    .frame(minWidth: 120, alignment: .center)
                    .foregroundStyle(isRecording ? .red : .primary)
            }
            .buttonStyle(.bordered)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isRecording ? Color.red : Color.clear, lineWidth: 2)
            )

            if keyCombo != nil {
                Button {
                    keyCombo = nil
                    GlobalHotkeyService.shared.set(nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .onDisappear { stopRecording() }
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        return keyCombo?.displayString ?? "Click to record"
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [self] event in
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            // Escape cancels without saving
            if event.keyCode == 53 {
                stopRecording()
                return nil
            }
            // Require at least one modifier so bare letters don't become hotkeys
            guard !mods.isEmpty else { return event }
            let combo = KeyCombo(keyCode: event.keyCode, modifiers: mods)
            keyCombo = combo
            GlobalHotkeyService.shared.set(combo)
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
    }
}
