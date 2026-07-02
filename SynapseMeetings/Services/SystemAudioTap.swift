import Foundation
import CoreAudio
import AudioToolbox

/// Wraps a Core Audio process tap (global system-output mixdown, excluding our
/// own process) plus an aggregate device combining that tap with the microphone.
/// Both sources share the aggregate's clock (tap drift-compensated), so
/// AVAudioEngine receives mic + system channels sample-aligned: the mic's
/// channels come first (it is the only sub-device), the tap's stereo mixdown after.
///
/// The first activation triggers macOS's "record system audio" consent prompt
/// (NSAudioCaptureUsageDescription). If the user denies it, tap creation fails
/// or the tap delivers silence — the caller falls back to mic-only either way.
@available(macOS 14.4, *)
@MainActor
final class SystemAudioTap {
    struct ActivationResult {
        let aggregateID: AudioDeviceID
        let micChannelCount: Int
    }

    enum TapError: LocalizedError {
        case noMicrophone
        case osStatus(String, OSStatus)

        var errorDescription: String? {
            switch self {
            case .noMicrophone:
                return "No input device available for the capture aggregate"
            case .osStatus(let what, let status):
                return "\(what) failed (OSStatus \(status))"
            }
        }
    }

    // `nonisolated(unsafe)` lets `deinit` — which Swift always runs nonisolated —
    // reach these handles to guarantee teardown on dealloc. Safety comes from
    // ownership, not isolation: `deinit` only runs once no references remain,
    // so a deinit-triggered teardown can never overlap a live `activate()` call.
    private nonisolated(unsafe) var tapID = AudioObjectID(kAudioObjectUnknown)
    private nonisolated(unsafe) var aggregateID = AudioDeviceID(kAudioObjectUnknown)

    deinit { teardown() }

    /// Builds tap + aggregate. On any failure, cleans up whatever was created
    /// and throws — the caller records mic-only.
    func activate(preferredMicUID: String) throws -> ActivationResult {
        guard let mic = Self.resolveMic(preferredUID: preferredMicUID) else {
            throw TapError.noMicrophone
        }

        let tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.ownProcessObjects())
        tapDescription.name = "Synapse Meetings System Tap"
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTapID = AudioObjectID(kAudioObjectUnknown)
        let tapStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw TapError.osStatus("AudioHardwareCreateProcessTap", tapStatus)
        }
        tapID = newTapID

        // Mic is the sole sub-device → its channels occupy indices 0..<micChannelCount.
        // The tap is drift-compensated against the mic's clock.
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Synapse Meetings Capture",
            kAudioAggregateDeviceUIDKey: "com.synapsemeetings.capture.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: mic.uid]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var newAggregateID = AudioDeviceID(kAudioObjectUnknown)
        let aggStatus = AudioHardwareCreateAggregateDevice(description as CFDictionary, &newAggregateID)
        guard aggStatus == noErr, newAggregateID != kAudioObjectUnknown else {
            teardown()
            throw TapError.osStatus("AudioHardwareCreateAggregateDevice", aggStatus)
        }
        aggregateID = newAggregateID

        return ActivationResult(
            aggregateID: aggregateID,
            micChannelCount: max(1, Int(mic.inputChannelCount))
        )
    }

    nonisolated func teardown() {
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioDeviceID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
    }

    // MARK: - Helpers

    /// Preferred mic if currently connected, else the system default input.
    private static func resolveMic(preferredUID: String) -> InputDevice? {
        let devices = AudioDeviceService.enumerateInputDevices()
        let trimmed = preferredUID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, let preferred = devices.first(where: { $0.uid == trimmed }) {
            return preferred
        }
        guard let defaultID = defaultInputDeviceID() else { return devices.first }
        return devices.first(where: { $0.id == defaultID }) ?? devices.first
    }

    private static func defaultInputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID
        )
        guard status == noErr, deviceID != kAudioObjectUnknown else { return nil }
        return deviceID
    }

    /// Our own process as an AudioObject, so Synapse's sounds are excluded
    /// from the tap. Empty array (capture everything) if translation fails.
    private static func ownProcessObjects() -> [AudioObjectID] {
        var pid = pid_t(ProcessInfo.processInfo.processIdentifier)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafeMutablePointer(to: &pid) { pidPtr in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                pidPtr,
                &size,
                &objectID
            )
        }
        guard status == noErr, objectID != kAudioObjectUnknown else { return [] }
        return [objectID]
    }
}
