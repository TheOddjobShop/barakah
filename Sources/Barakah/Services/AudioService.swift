import Foundation
import AVFoundation
import Observation
import OSLog

/// Plays the athan.
///
/// Barakah plays audio itself rather than attaching a sound to a user
/// notification, for three reasons: notification sounds are truncated at 30
/// seconds and a real adhan is two to four minutes; they cannot be stopped once
/// started; and they give no playback position to show or act on. Owning
/// playback is what makes "stop it by clicking the menu bar" possible.
@MainActor
@Observable
public final class AudioService: NSObject {
    /// The prayer currently being sounded, if any.
    public private(set) var playingPrayer: PrayerKind?
    /// Seconds elapsed in the current playback.
    public private(set) var elapsed: TimeInterval = 0
    /// Total length of the current audio, when known.
    public private(set) var duration: TimeInterval = 0
    /// Last error surfaced to the user, e.g. a custom file that has gone missing.
    public private(set) var lastError: String?

    public var isPlaying: Bool { playingPrayer != nil }

    public var progress: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, elapsed / duration))
    }

    /// Called when playback ends on its own or is stopped.
    public var onFinish: ((PrayerKind) -> Void)?

    /// Posted whenever playback starts or stops, so the menu bar can switch
    /// itself into a stop button on the instant rather than on its next tick.
    public static let playbackChanged = Notification.Name("dev.justin06lee.barakah.playbackChanged")

    private func announce() {
        NotificationCenter.default.post(name: Self.playbackChanged, object: nil)
    }

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    private var fadeTask: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private let log = Logger(subsystem: Barakah.subsystem, category: "audio")

    public override init() { super.init() }

    /// Start the athan for `prayer`. Any playback already running is replaced.
    public func play(prayer: PrayerKind, settings: SettingsData) {
        let sound = settings.sound(for: prayer)
        guard !sound.isSilent else {
            onFinish?(prayer)
            return
        }
        stop(notify: false)

        do {
            let url = try resolve(sound)
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.delegate = self
            newPlayer.volume = Float(settings.athanVolume)
            newPlayer.prepareToPlay()
            guard newPlayer.play() else { throw AudioError.couldNotStart }

            player = newPlayer
            playingPrayer = prayer
            duration = newPlayer.duration
            elapsed = 0
            lastError = nil
            startTicker()
            announce()

            if settings.athanMaxSeconds > 0 {
                let limit = Double(settings.athanMaxSeconds)
                autoStopTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(limit))
                    guard !Task.isCancelled else { return }
                    self?.stop()
                }
            }
            log.info("playing athan for \(prayer.name, privacy: .public)")
        } catch {
            // Falling back to the built-in chime means a missing or moved custom
            // file still results in an audible athan rather than silence.
            log.error("athan playback failed: \(error.localizedDescription)")
            lastError = Self.describe(error, sound: sound)
            if case .chime = sound {
                onFinish?(prayer)
            } else {
                var fallback = settings
                fallback.athanSound = .chime
                fallback.fajrAthanSound = nil
                play(prayer: prayer, settings: fallback)
            }
        }
    }

    /// Preview a sound from the settings screen, at the configured volume.
    public func preview(_ sound: AthanSound, volume: Double) {
        stop(notify: false)
        guard !sound.isSilent, let url = try? resolve(sound) else { return }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.delegate = self
        player?.volume = Float(volume)
        player?.play()
        playingPrayer = nil
        duration = player?.duration ?? 0
        elapsed = 0
        startTicker()
        announce()
    }

    /// Stop playback, fading out briefly so it does not cut off harshly.
    public func stop(notify: Bool = true) {
        autoStopTask?.cancel(); autoStopTask = nil
        ticker?.invalidate(); ticker = nil
        fadeTask?.cancel()

        let finished = playingPrayer
        playingPrayer = nil
        elapsed = 0
        duration = 0

        if let current = player, current.isPlaying {
            current.setVolume(0, fadeDuration: 0.35)
            fadeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                current.stop()
                if self?.player === current { self?.player = nil }
            }
        } else {
            player = nil
        }

        announce()
        if notify, let finished { onFinish?(finished) }
    }

    /// Resolve a sound to a playable file URL.
    private func resolve(_ sound: AthanSound) throws -> URL {
        switch sound {
        case .chime:
            return try ChimeSynthesiser.url()

        case .bundled(let name):
            guard let url = AthanLibrary.url(forResource: name) else {
                throw AudioError.bundledSoundMissing(name)
            }
            return url

        case .custom(let bookmark, _):
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            guard url.startAccessingSecurityScopedResource() else {
                throw AudioError.customSoundUnreadable
            }
            // Released once AVAudioPlayer has the file open; keeping the scope for
            // the whole app lifetime would leak a sandbox grant per play.
            defer { url.stopAccessingSecurityScopedResource() }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw AudioError.customSoundUnreadable
            }
            return url

        case .silent:
            throw AudioError.silent
        }
    }

    /// Create a bookmark for a user-chosen athan file.
    public static func bookmark(for url: URL) throws -> AthanSound {
        let data = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        return .custom(bookmark: data, displayName: url.deletingPathExtension().lastPathComponent)
    }

    private func startTicker() {
        ticker?.invalidate()
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                self.elapsed = player.currentTime
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
    }

    private static func describe(_ error: Error, sound: AthanSound) -> String {
        switch error {
        case AudioError.customSoundUnreadable:
            "“\(sound.label)” could not be opened. Choose the athan file again in Settings."
        case AudioError.bundledSoundMissing(let name):
            "The bundled sound “\(name)” is missing from this build."
        default:
            "Could not play the athan: \(error.localizedDescription)"
        }
    }

    enum AudioError: Error {
        case couldNotStart
        case bundledSoundMissing(String)
        case customSoundUnreadable
        case silent
    }
}

extension AudioService: AVAudioPlayerDelegate {
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.player === player else { return }
            self.stop()
        }
    }

    nonisolated public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        Task { @MainActor [weak self] in
            self?.lastError = error?.localizedDescription
            self?.stop()
        }
    }
}
