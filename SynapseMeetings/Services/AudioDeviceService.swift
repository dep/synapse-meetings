import Foundation
import CoreAudio
import AudioToolbox

struct InputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let manufacturer: String
    let inputChannelCount: UInt32
}

@MainActor
final class AudioDeviceService: ObservableObject {
    @Published private(set) var inputDevices: [InputDevice] = []

    init() {
        refresh()
        installChangeListener()
    }

    func refresh() {
        inputDevices = Self.enumerateInputDevices()
    }

    /// Resolves a saved UID to a live AudioDeviceID, or nil if the device isn't currently connected.
    func deviceID(forUID uid: String) -> AudioDeviceID? {
        inputDevices.first(where: { $0.uid == uid })?.id
    }

    func device(forUID uid: String) -> InputDevice? {
        inputDevices.first(where: { $0.uid == uid })
    }

    // MARK: - CoreAudio listener

    private var listenerInstalled = false

    private func installChangeListener() {
        guard !listenerInstalled else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            DispatchQueue.main
        ) { [weak self] _, _ in
            // The listener block can be called repeatedly during a single change event.
            // Refreshing the list is cheap and idempotent.
            Task { @MainActor in
                self?.refresh()
            }
        }
        if status == noErr {
            listenerInstalled = true
        } else {
            NSLog("AudioDeviceService: failed to install device-list listener (status \(status))")
        }
    }

    // MARK: - Enumeration

    private static func enumerateInputDevices() -> [InputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let sizeStatus = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize
        )
        guard sizeStatus == noErr, dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &ids
        )
        guard getStatus == noErr else { return [] }

        var result: [InputDevice] = []
        for id in ids {
            let inputs = inputChannelCount(for: id)
            guard inputs > 0 else { continue }
            guard let uid = stringProperty(deviceID: id, selector: kAudioDevicePropertyDeviceUID) else { continue }
            let name = stringProperty(deviceID: id, selector: kAudioObjectPropertyName) ?? "Unknown device"
            let mfr = stringProperty(deviceID: id, selector: kAudioObjectPropertyManufacturer) ?? ""
            result.append(InputDevice(
                id: id,
                uid: uid,
                name: name,
                manufacturer: mfr,
                inputChannelCount: inputs
            ))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func inputChannelCount(for deviceID: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return 0 }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(dataSize))
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, bufferList) == noErr else { return 0 }

        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        var total: UInt32 = 0
        for buffer in buffers {
            total += buffer.mNumberChannels
        }
        return total
    }

    private static func stringProperty(deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString?
        let status = withUnsafeMutablePointer(to: &value) { ptr -> OSStatus in
            ptr.withMemoryRebound(to: UInt8.self, capacity: Int(size)) { rebound in
                AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, rebound)
            }
        }
        guard status == noErr, let result = value else { return nil }
        return result as String
    }
}
