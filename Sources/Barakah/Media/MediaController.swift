import Foundation
import Observation
import OSLog

/// What Barakah actually did to the user's media, so it can be shown in the UI
/// and undone precisely afterwards.
public struct MediaInterruption: Sendable, Equatable {
    /// Scriptable players that were playing and have been paused by us.
    public var pausedPlayers: [String] = []
    /// True if a MediaRemote pause was issued.
    public var sentMediaRemotePause: Bool = false
    /// True if audio was genuinely playing when the pause was sent — the
    /// evidence that makes resuming safe.
    public var mediaRemoteStoppedAudio: Bool = false
    /// Applications observed producing audio at the moment of interruption.
    public var sourcesAtInterruption: [String] = []
    /// True if system output was muted by us.
    public var mutedOutput: Bool = false
    /// Human description of what was playing, when we could tell.
    public var nowPlayingDescription: String?

    public var didAnything: Bool {
        !pausedPlayers.isEmpty || mediaRemoteStoppedAudio || mutedOutput
    }

    /// Whether anything here can be put back.
    public var isResumable: Bool {
        !pausedPlayers.isEmpty || mediaRemoteStoppedAudio || nowPlayingDescription != nil
    }

    /// One-line summary for the athan window, e.g. "Paused Spotify".
    public var summary: String? {
        var parts: [String] = []
        if !pausedPlayers.isEmpty {
            parts.append("Paused \(pausedPlayers.formattedList())")
        } else if mediaRemoteStoppedAudio {
            parts.append(nowPlayingDescription.map { "Paused \($0)" } ?? "Paused playback")
        }
        if mutedOutput { parts.append("output muted") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// Decides *how* to silence media at athan time, in order of precision, and
/// remembers enough to put things back exactly as they were.
///
/// The layering matters. MediaRemote reaches the most players but tells us the
/// least (Apple gates now-playing reads on current systems). AppleScript reaches
/// fewer players but answers questions honestly. Muting reaches everything but
/// stops nothing. Used together they cover the real world; used alone each has a
/// visible hole.
@MainActor
@Observable
public final class MediaController {
    /// The interruption currently in effect, if any.
    public private(set) var active: MediaInterruption?
    /// Set when a scriptable player refused automation, so the UI can prompt.
    public private(set) var needsAutomationPermission = false

    private let bridge = MediaRemoteBridge.shared
    private let scripts = ScriptablePlayerController.shared
    private let muter = OutputMuter.shared
    /// Serialises interruptions. Two overlapping calls both used to observe
    /// `active == nil`, and the loser's paused players were never resumed —
    /// and if the loser had done the muting, output stayed muted through quit.
    private var inFlight: Task<MediaInterruption, Never>?
    private let log = Logger(subsystem: Barakah.subsystem, category: "media")

    public init() {}

    /// True if at least one way of pausing media is available on this system.
    public var canPauseMedia: Bool { bridge.canSendCommands || !ScriptablePlayer.all.isEmpty }

    /// Whether now-playing state can be inspected. When false, Barakah still
    /// pauses correctly — it just cannot describe what it paused.
    public var canDetectPlayback: Bool { bridge.canReadState }

    /// Silence whatever is playing, according to `mode`.
    @discardableResult
    public func interrupt(mode: MediaPauseMode, settings: SettingsData) async -> MediaInterruption {
        guard mode.pausesPlayers || mode.mutesOutput else { return MediaInterruption() }
        let previous = inFlight
        let task = Task { @MainActor [weak self] () -> MediaInterruption in
            _ = await previous?.value
            guard let self else { return MediaInterruption() }
            return await self.performInterrupt(mode: mode, settings: settings)
        }
        inFlight = task
        return await task.value
    }

    private func performInterrupt(mode: MediaPauseMode, settings: SettingsData) async -> MediaInterruption {

        // Anything still paused from a previous athan is released first, so the
        // record of "what to resume" never straddles two prayers.
        if active != nil { await resume(force: true) }

        var interruption = MediaInterruption()
        let excluded = Set(settings.mediaExcludedBundleIDs)

        // Snapshot what is audibly playing *first*, through public CoreAudio.
        // This is the only reliable account of what is going on: the private
        // now-playing API refuses to answer unentitled apps on current macOS,
        // and the per-process flag is sticky for a second or two after a pause,
        // so it has to be read before anything is touched.
        let allPlaying = AudioActivity.outputtingApplications()
        let playing = allPlaying.filter { source in
            guard let bundleID = source.bundleIdentifier else { return true }
            return !excluded.contains(bundleID)
        }
        interruption.sourcesAtInterruption = playing.map(\.displayName)

        // Layer 1 — ask scriptable players directly. Done first because it is the
        // only layer that can tell us what was genuinely playing, which is what
        // makes an accurate resume possible.
        if settings.useAppleScript {
            let playing = await scripts.playingPlayers(excluding: excluded)
            for player in playing where await scripts.pause(player) {
                interruption.pausedPlayers.append(player.bundleIdentifier)
            }
            needsAutomationPermission = await scripts.hasDeniedPlayers
        }

        // Layer 2 — MediaRemote, for everything else: browsers, IINA, and any
        // app that publishes to Now Playing.
        if settings.useMediaRemote, bridge.canSendCommands {
            let nowPlaying = await bridge.nowPlaying()

            // Whatever is still making noise that the scriptable layer did not
            // already stop.
            let handledBundleIDs = Set(interruption.pausedPlayers)
            let unhandled = playing.filter { source in
                guard let bundleID = source.bundleIdentifier else { return true }
                return !handledBundleIDs.contains(bundleID)
            }

            // Prefer the track title when macOS will give it to us, and fall
            // back to the application name, which CoreAudio always will.
            interruption.nowPlayingDescription = nowPlaying?.displayDescription
                ?? unhandled.first.map(\.displayName)

            let ownerExcluded = nowPlaying?.bundleIdentifier.map(excluded.contains) ?? false
            // Already handled by the precise layer above?
            let handledByScript = nowPlaying?.bundleIdentifier
                .map(interruption.pausedPlayers.contains) ?? false

            // Whether to fire the blind pause at all.
            //
            // The now-playing owner's bundle id is usually unavailable on
            // current macOS, so gating on that alone silently ignored the user's
            // exclusion list — someone who excluded Spotify still had Spotify
            // paused every prayer. The CoreAudio snapshot is the reliable
            // source, so the decision is made from that instead:
            //   - something unexcluded is playing  -> pause it
            //   - only excluded things are playing -> leave them alone
            //   - nothing detected, and detection works -> nothing to pause
            //   - detection unavailable             -> pause as a best effort
            let shouldPause: Bool
            if !unhandled.isEmpty {
                shouldPause = true
            } else if !allPlaying.isEmpty {
                shouldPause = false          // everything playing was excluded or scripted
            } else {
                shouldPause = !AudioActivity.isSupported
            }

            if !ownerExcluded && !handledByScript && shouldPause {
                // Deliberately an explicit pause and never a toggle: if nothing is
                // playing this is a no-op, whereas a toggle would start music in
                // the middle of the adhan.
                if bridge.send(.pause) {
                    interruption.sentMediaRemotePause = true
                    // Anything still sounding that the scriptable layer did not
                    // handle is what this pause was for. Sampled before the
                    // pause, where the signal is immediate and accurate.
                    interruption.mediaRemoteStoppedAudio = !unhandled.isEmpty
                }
            }
        }

        // Layer 3 — the guarantee of silence, for sources neither layer reaches.
        if mode.mutesOutput, muter.mute() {
            interruption.mutedOutput = true
        }

        active = interruption.didAnything ? interruption : nil
        log.info("interrupted media: \(interruption.summary ?? "nothing was playing", privacy: .public)")
        return interruption
    }

    /// Put back what we took away.
    ///
    /// Only players we actually paused are resumed, and a bare MediaRemote pause
    /// is only reversed when we had positive evidence something was playing —
    /// otherwise "resume" could start audio the user never asked for.
    public func resume(force: Bool = false) async {
        guard let interruption = active else {
            if force { muter.restore() }
            return
        }
        active = nil

        if interruption.mutedOutput { muter.restore() }

        for bundleID in interruption.pausedPlayers {
            guard let player = ScriptablePlayer.all.first(where: { $0.bundleIdentifier == bundleID }) else { continue }
            await scripts.play(player)
        }

        // `mediaRemoteStoppedAudio` is the *only* acceptable evidence here.
        //
        // A now-playing description is not evidence: MediaRemote reports the
        // loaded track of whichever app holds Now Playing regardless of whether
        // it is playing, so a paused YouTube tab in a background browser
        // produces a perfectly good description. Accepting that as proof meant
        // that pausing Spotify at Maghrib also *started* the paused video.
        if interruption.sentMediaRemotePause, interruption.mediaRemoteStoppedAudio {
            bridge.send(.play)
        }

        log.info("resumed media")
    }

    /// Drop any record of an interruption without touching playback — used when
    /// the user says "don't resume".
    public func forget() {
        if active?.mutedOutput == true { muter.restore() }
        active = nil
    }

    /// A quick probe used by the settings screen to show the user what will and
    /// will not work on their machine, rather than making them find out at Fajr.
    public func diagnostics() async -> MediaDiagnostics {
        let nowPlaying = await bridge.nowPlaying()
        return MediaDiagnostics(
            mediaRemoteLoaded: bridge.canSendCommands,
            nowPlayingReadable: nowPlaying != nil,
            nowPlayingDescription: nowPlaying?.displayDescription,
            detectedPlayers: await scripts.playingPlayers().map(\.applicationName),
            automationDenied: await scripts.hasDeniedPlayers,
            audioSources: AudioActivity.outputtingApplications().map(\.displayName),
            perProcessAudioSupported: AudioActivity.isSupported
        )
    }
}

public struct MediaDiagnostics: Sendable, Equatable {
    public var mediaRemoteLoaded: Bool
    public var nowPlayingReadable: Bool
    public var nowPlayingDescription: String?
    public var detectedPlayers: [String]
    public var automationDenied: Bool
    /// Applications CoreAudio reports as currently producing sound.
    public var audioSources: [String] = []
    /// Whether this macOS exposes the per-process audio API at all.
    public var perProcessAudioSupported: Bool = true
}

extension Array where Element == String {
    /// "Spotify", "Spotify and Music", "Spotify, Music and VLC".
    func formattedList() -> String {
        let names = map { bundleID -> String in
            ScriptablePlayer.all
                .first { $0.bundleIdentifier == bundleID }?
                .applicationName ?? bundleID
        }
        switch names.count {
        case 0: return ""
        case 1: return names[0]
        case 2: return "\(names[0]) and \(names[1])"
        default: return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
        }
    }
}
