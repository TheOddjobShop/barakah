import Foundation
import CoreAudio
import AudioToolbox
import OSLog

/// Mutes the system's default output device and restores it afterwards.
///
/// This is the backstop layer. It does not *stop* anything — a video keeps
/// running, a game keeps ticking — but it guarantees silence during the adhan
/// even for sources Barakah cannot reach: WebRTC calls, games, emulators, and
/// browsers that never publish to Now Playing.
///
/// Muting is only ever applied around an athan, and the previous state is always
/// captured first so the user's own mute never gets un-muted by us.
final class OutputMuter: @unchecked Sendable {
    static let shared = OutputMuter()

    /// What the output device looked like before Barakah touched it.
    ///
    /// Persisted, because the worst failure this class can produce is leaving
    /// somebody's Mac silent. A crash or force-quit mid-athan skips
    /// `applicationWillTerminate`, and with the volume fallback the original
    /// level would die with the process and be unrecoverable.
    private struct PreviousState: Codable {
        var deviceID: AudioDeviceID
        var wasMuted: Bool?
        var previousVolume: Float32?
    }

    private let lock = NSLock()
    private var previous: PreviousState?
    private let log = Logger(subsystem: Barakah.subsystem, category: "output")

    private init() {}

    /// Where the "we muted the output" marker lives between launches.
    private static var markerURL: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = base.appendingPathComponent("Barakah", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("output-mute-state.json")
    }

    /// Undo a mute left behind by a previous run that died before restoring.
    /// Called once at launch.
    func recoverIfNeeded() {
        guard let data = try? Data(contentsOf: Self.markerURL),
              let state = try? JSONDecoder().decode(PreviousState.self, from: data) else { return }
        try? FileManager.default.removeItem(at: Self.markerURL)

        log.notice("restoring output muted by a previous run")
        if let wasMuted = state.wasMuted { _ = Self.writeMute(state.deviceID, muted: wasMuted) }
        if let volume = state.previousVolume { _ = Self.writeVolume(state.deviceID, volume: volume) }
    }

    private func persist(_ state: PreviousState?) {
        guard let state else {
            try? FileManager.default.removeItem(at: Self.markerURL)
            return
        }
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: Self.markerURL, options: .atomic)
    }

    var isMuted: Bool {
        lock.lock(); defer { lock.unlock() }
        return previous != nil
    }

    /// Mute the current default output. Returns false if the device supports
    /// neither mute nor software volume, in which case nothing was changed.
    @discardableResult
    func mute() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard previous == nil, let device = Self.defaultOutputDevice() else { return false }

        // Preferred path: the device has a real mute control.
        if let wasMuted = Self.readMute(device) {
            guard Self.writeMute(device, muted: true) else { return false }
            let state = PreviousState(deviceID: device, wasMuted: wasMuted, previousVolume: nil)
            previous = state
            persist(state)
            log.debug("muted output device \(device)")
            return true
        }

        // Fallback: drop the virtual main volume to zero and remember it.
        if let volume = Self.readVolume(device) {
            guard Self.writeVolume(device, volume: 0) else { return false }
            let state = PreviousState(deviceID: device, wasMuted: nil, previousVolume: volume)
            previous = state
            persist(state)
            log.debug("zeroed volume on output device \(device)")
            return true
        }

        log.notice("default output device exposes no mute or volume control")
        return false
    }

    /// Restore whatever was changed by `mute()`. Safe to call when not muted.
    func restore() {
        lock.lock(); defer { lock.unlock() }
        guard let state = previous else { return }
        previous = nil

        var restored = true
        if let wasMuted = state.wasMuted {
            restored = Self.writeMute(state.deviceID, muted: wasMuted) && restored
        }
        if let volume = state.previousVolume {
            restored = Self.writeVolume(state.deviceID, volume: volume) && restored
        }

        // A device that vanished mid-athan — AirPods pulled out — cannot be
        // written to now, and CoreAudio remembers per-device mute. Keeping the
        // marker means the next launch tries again rather than leaving those
        // headphones silent forever.
        if restored {
            persist(nil)
        } else {
            log.notice("could not restore device \(state.deviceID); will retry next launch")
        }
        log.debug("restored output device \(state.deviceID)")
    }

    // MARK: - CoreAudio plumbing

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device
        )
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func muteAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static func volumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: OutputMuter.virtualMainVolumeSelector,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    /// `'vmvc'` — the virtual main volume selector. Spelled out rather than
    /// imported because Apple has renamed the symbol across SDK versions
    /// (`VirtualMasterVolume` → `VirtualMainVolume`) while the value never moved.
    private static let virtualMainVolumeSelector: AudioObjectPropertySelector = {
        let chars: [UInt32] = [0x76, 0x6d, 0x76, 0x63]  // v m v c
        return (chars[0] << 24) | (chars[1] << 16) | (chars[2] << 8) | chars[3]
    }()

    private static func readMute(_ device: AudioDeviceID) -> Bool? {
        var address = muteAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func writeMute(_ device: AudioDeviceID, muted: Bool) -> Bool {
        var address = muteAddress()
        var isSettable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &isSettable) == noErr,
              isSettable.boolValue else { return false }
        var value: UInt32 = muted ? 1 : 0
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    private static func readVolume(_ device: AudioDeviceID) -> Float32? {
        var address = volumeAddress()
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func writeVolume(_ device: AudioDeviceID, volume: Float32) -> Bool {
        var address = volumeAddress()
        var isSettable = DarwinBoolean(false)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectIsPropertySettable(device, &address, &isSettable) == noErr,
              isSettable.boolValue else { return false }
        var value = volume
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }
}
