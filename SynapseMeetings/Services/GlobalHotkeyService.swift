import AppKit
import Combine

/// Persists and fires a user-configurable global hotkey for toggling recording.
/// Key combo is stored in UserDefaults as two integers: keyCode and modifierFlags raw value.
final class GlobalHotkeyService: ObservableObject {

    static let shared = GlobalHotkeyService()

    /// Published so views can display the current shortcut.
    @Published private(set) var keyCombo: KeyCombo?

    var onToggleRecording: (() -> Void)?

    private var globalMonitor: Any?
    private var localMonitor: Any?

    private init() {
        keyCombo = KeyCombo.load()
        registerMonitors()
    }

    // MARK: - Public

    func set(_ combo: KeyCombo?) {
        keyCombo = combo
        if let combo { combo.save() } else { KeyCombo.clear() }
        registerMonitors()
    }

    // MARK: - Private

    private func registerMonitors() {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor  { NSEvent.removeMonitor(l); localMonitor  = nil }

        guard let combo = keyCombo else { return }

        let handler: (NSEvent) -> Void = { [weak self] event in
            guard event.keyCode == combo.keyCode,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == combo.modifiers
            else { return }
            DispatchQueue.main.async { self?.onToggleRecording?() }
        }

        // Global monitor fires when the app is in the background.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handler)
        // Local monitor fires when the app is focused (prevents the key from also triggering other bindings).
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.keyCode == combo.keyCode,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == combo.modifiers
            else { return event }
            DispatchQueue.main.async { self.onToggleRecording?() }
            return nil // consume the event
        }
    }
}

// MARK: - KeyCombo

struct KeyCombo: Equatable {
    let keyCode: UInt16
    let modifiers: NSEvent.ModifierFlags

    // Human-readable label, e.g. "⌃⌥R"
    var displayString: String {
        modifiers.displayString + keyCodeDisplayString
    }

    private var keyCodeDisplayString: String {
        KeyCombo.keyCodeToString[keyCode] ?? "(\(keyCode))"
    }

    // MARK: Persistence

    private static let keyCodeKey = "globalHotkey.keyCode"
    private static let modifiersKey = "globalHotkey.modifiers"

    static func load() -> KeyCombo? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: keyCodeKey) != nil else { return nil }
        let kc = UInt16(defaults.integer(forKey: keyCodeKey))
        let raw = UInt(bitPattern: defaults.integer(forKey: modifiersKey))
        return KeyCombo(keyCode: kc, modifiers: NSEvent.ModifierFlags(rawValue: raw))
    }

    func save() {
        UserDefaults.standard.set(Int(keyCode), forKey: KeyCombo.keyCodeKey)
        UserDefaults.standard.set(Int(bitPattern: modifiers.rawValue), forKey: KeyCombo.modifiersKey)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: keyCodeKey)
        UserDefaults.standard.removeObject(forKey: modifiersKey)
    }

    // MARK: Key code → display string (common keys)
    static let keyCodeToString: [UInt16: String] = [
        0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
        8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
        16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
        23: "5", 24: "=", 25: "9", 26: "7", 27: "-", 28: "8", 29: "0",
        30: "]", 31: "O", 32: "U", 33: "[", 34: "I", 35: "P", 36: "↩",
        37: "L", 38: "J", 39: "'", 40: "K", 41: ";", 42: "\\", 43: ",",
        44: "/", 45: "N", 46: "M", 47: ".", 48: "⇥", 49: "Space",
        51: "⌫", 53: "⎋", 96: "F5", 97: "F6", 98: "F7", 99: "F3",
        100: "F8", 101: "F9", 103: "F11", 105: "F13", 107: "F14",
        109: "F10", 111: "F12", 113: "F15", 114: "⌦", 115: "↖",
        116: "⇞", 117: "⌦", 119: "↘", 121: "⇟", 122: "F1", 120: "F2",
        160: "F5", 123: "←", 124: "→", 125: "↓", 126: "↑",
    ]
}

extension NSEvent.ModifierFlags {
    var displayString: String {
        var s = ""
        if contains(.control) { s += "⌃" }
        if contains(.option)  { s += "⌥" }
        if contains(.shift)   { s += "⇧" }
        if contains(.command) { s += "⌘" }
        return s
    }
}
