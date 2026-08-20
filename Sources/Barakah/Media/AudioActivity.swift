import CoreAudio
import AppKit
import Foundation

/// An application that is currently pushing audio to the output device.
public struct AudioSource: Sendable, Hashable {
    public var pid: pid_t
    public var bundleIdentifier: String?
    public var name: String

    public var displayName: String { name }
}

/// Answers "what is making sound right now", using only public CoreAudio.
///
/// This exists because the obvious answer does not work. The private
/// now-playing API has, since macOS 15.4, refused to tell an unentitled process
/// whether anything is playing — measured on macOS 26, where it reports "not
/// playing" while audio is plainly audible. Without a substitute, Barakah could
/// pause media but never safely resume it, and could only ever say "paused
/// playback" rather than "paused Spotify".
///
/// `kAudioHardwarePropertyProcessObjectList` (macOS 14.4+) closes both gaps. It
/// enumerates every process with an audio presence, and
/// `kAudioProcessPropertyIsRunningOutput` says which of them are actually
/// producing output — with a PID that resolves to a real application name.
///
/// One measured caveat drives how this is used: the flag is *sticky on the way
/// down*. A process that has just been paused keeps reporting output for a
/// second or two. So Barakah samples *before* it pauses anything, where the
/// signal is immediate and accurate, and never tries to detect a pause by
/// watching the flag fall.
public enum AudioActivity {

    /// Applications currently producing audio output, excluding Barakah itself.
    public static func outputtingApplications() -> [AudioSource] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var sources: [AudioSource] = []

        for object in processObjects() {
            guard let isOutputting = flag(object, kAudioProcessPropertyIsRunningOutput),
                  isOutputting,
                  let processID = pid(of: object),
                  processID != ownPID else { continue }

            let application = NSRunningApplication(processIdentifier: processID)
            sources.append(AudioSource(
                pid: processID,
                bundleIdentifier: application?.bundleIdentifier,
                name: application?.localizedName ?? processName(processID) ?? "an app"
            ))
        }
        return sources
    }

    /// Whether anything at all is producing audio.
    public static var isAnythingPlaying: Bool {
        !outputtingApplications().isEmpty
    }

    /// Whether this macOS exposes the per-process audio API at all.
    public static var isSupported: Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        return AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address)
    }

    // MARK: - CoreAudio plumbing

    private static func processObjects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectHasProperty(system, &address),
              AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0 else { return [] }

        var objects = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else {
            return []
        }
        return objects
    }

    private static func flag(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> Bool? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value != 0
    }

    private static func pid(of object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else {
            return nil
        }
        return value > 0 ? value : nil
    }

    /// Fallback for helper processes that are not applications — a browser's
    /// audio often comes from a child process with no `NSRunningApplication`.
    private static func processName(_ processID: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }
}
