import AVFoundation
import CoreAudio

// Microphone discovery and selection.
//
// Bluetooth headphones switch to the low-bandwidth headset profile the moment
// their microphone is opened, which also degrades what you hear. So unless a
// specific mic is chosen, Viva records from the Mac's built-in microphone and
// leaves the headphones as a playback-only device.
struct AudioInput: Identifiable, Hashable {
    let uid: String
    let name: String
    let kind: String  // "Built-in", "Bluetooth", "USB", "iPhone", "Virtual" or ""
    var id: String { uid }
}

enum AudioInputs {
    private static func devices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices
    }

    static func available() -> [AudioInput] {
        devices().map { AudioInput(uid: $0.uniqueID, name: $0.localizedName, kind: kind(of: $0)) }
    }

    static func kind(of device: AVCaptureDevice) -> String {
        switch UInt32(bitPattern: device.transportType) {
        case kAudioDeviceTransportTypeBuiltIn: return "Built-in"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "Bluetooth"
        case kAudioDeviceTransportTypeUSB: return "USB"
        case kAudioDeviceTransportTypeContinuityCaptureWired,
             kAudioDeviceTransportTypeContinuityCaptureWireless: return "iPhone"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate: return "Virtual"
        default: return ""
        }
    }

    static func isBuiltIn(_ device: AVCaptureDevice) -> Bool {
        UInt32(bitPattern: device.transportType) == kAudioDeviceTransportTypeBuiltIn
    }

    // The mic to record with: the chosen one if it is still connected, otherwise
    // the built-in mic, otherwise whatever macOS has as the default input.
    static func device(preferredUID: String?) -> AVCaptureDevice? {
        let all = devices()
        if let uid = preferredUID, !uid.isEmpty, let chosen = all.first(where: { $0.uniqueID == uid }) {
            return chosen
        }
        if let builtIn = all.first(where: isBuiltIn) { return builtIn }
        return AVCaptureDevice.default(for: .audio)
    }
}
