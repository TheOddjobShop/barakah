import Foundation
import AppKit
import OSLog

/// A media app Barakah can query and control precisely over Apple Events.
///
/// This layer exists because MediaRemote can only tell us about *one* now-playing
/// app and, on recent systems, may refuse to tell us anything at all. Scriptable
/// players can be asked directly whether they are playing — which is what makes
/// "resume exactly what I paused" possible rather than guesswork.
struct ScriptablePlayer: Sendable, Hashable {
    let bundleIdentifier: String
    let applicationName: String
    /// AppleScript returning "playing", "paused" or "stopped".
    let stateScript: String
    let pauseScript: String
    let playScript: String

    static let spotify = ScriptablePlayer(
        bundleIdentifier: "com.spotify.client",
        applicationName: "Spotify",
        stateScript: #"tell application id "com.spotify.client" to return player state as text"#,
        pauseScript: #"tell application id "com.spotify.client" to pause"#,
        playScript: #"tell application id "com.spotify.client" to play"#
    )

    static let music = ScriptablePlayer(
        bundleIdentifier: "com.apple.Music",
        applicationName: "Music",
        stateScript: #"tell application id "com.apple.Music" to return player state as text"#,
        pauseScript: #"tell application id "com.apple.Music" to pause"#,
        playScript: #"tell application id "com.apple.Music" to play"#
    )

    static let tv = ScriptablePlayer(
        bundleIdentifier: "com.apple.TV",
        applicationName: "TV",
        stateScript: #"tell application id "com.apple.TV" to return player state as text"#,
        pauseScript: #"tell application id "com.apple.TV" to pause"#,
        playScript: #"tell application id "com.apple.TV" to play"#
    )

    /// VLC exposes a boolean `playing` and a `play` command that *toggles*, so
    /// both scripts are guarded by the current state to stay idempotent.
    ///
    /// The state script has to be a full `tell` block rather than the compact
    /// `tell … to if …` form the other two use: AppleScript's one-line `if`
    /// accepts no `else` clause, and silently fails to compile with one
    /// (`-2740`), which would leave VLC permanently undetected.
    static let vlc = ScriptablePlayer(
        bundleIdentifier: "org.videolan.vlc",
        applicationName: "VLC",
        stateScript: #"""
        tell application id "org.videolan.vlc"
            if playing then
                return "playing"
            else
                return "paused"
            end if
        end tell
        """#,
        pauseScript: #"tell application id "org.videolan.vlc" to if playing then play"#,
        playScript: #"tell application id "org.videolan.vlc" to if not playing then play"#
    )

    /// QuickTime can hold several documents at once; act on all of them.
    static let quickTime = ScriptablePlayer(
        bundleIdentifier: "com.apple.QuickTimePlayerX",
        applicationName: "QuickTime Player",
        stateScript: #"""
        tell application id "com.apple.QuickTimePlayerX"
            repeat with doc in documents
                if playing of doc then return "playing"
            end repeat
            return "paused"
        end tell
        """#,
        pauseScript: #"""
        tell application id "com.apple.QuickTimePlayerX"
            repeat with doc in documents
                if playing of doc then pause doc
            end repeat
        end tell
        """#,
        playScript: #"""
        tell application id "com.apple.QuickTimePlayerX"
            repeat with doc in documents
                play doc
            end repeat
        end tell
        """#
    )

    /// Podcasts.app is deliberately absent: it ships no scripting dictionary at
    /// all, so every term addressed to it fails to compile (-2740). It is still
    /// covered, via Now Playing, which is the layer that reaches apps Apple never
    /// made scriptable.
    static let all: [ScriptablePlayer] = [.spotify, .music, .tv, .vlc, .quickTime]
}

/// Runs the scripts above, never launching an app that is not already open.
///
/// Every call is wrapped so that a missing Automation grant, a hung app, or a
/// renamed scripting term degrades to "this player is unavailable" instead of
/// taking the athan down with it.
actor ScriptablePlayerController {
    static let shared = ScriptablePlayerController()

    private let log = Logger(subsystem: Barakah.subsystem, category: "applescript")
    /// Bundle IDs that returned "not authorised" so we stop hammering them and
    /// stop provoking repeated permission dialogs.
    private var deniedBundleIDs: Set<String> = []

    /// AppleEvent error for "user has not granted Automation permission".
    private static let notAuthorizedCode = -1743
    /// AppleEvent error for "the application isn't running".
    private static let notRunningCode = -600

    /// Players that are installed, currently running, and reporting playback.
    func playingPlayers(excluding excluded: Set<String> = []) async -> [ScriptablePlayer] {
        var playing: [ScriptablePlayer] = []
        for player in ScriptablePlayer.all where !excluded.contains(player.bundleIdentifier) {
            guard isRunning(player), !deniedBundleIDs.contains(player.bundleIdentifier) else { continue }
            if let state = run(player.stateScript, for: player)?.lowercased(), state.contains("playing") {
                playing.append(player)
            }
        }
        return playing
    }

    @discardableResult
    func pause(_ player: ScriptablePlayer) -> Bool {
        guard isRunning(player) else { return false }
        return run(player.pauseScript, for: player) != nil
    }

    @discardableResult
    func play(_ player: ScriptablePlayer) -> Bool {
        guard isRunning(player) else { return false }
        return run(player.playScript, for: player) != nil
    }

    /// True once any player has refused automation, so the UI can offer to open
    /// the right settings pane instead of silently doing nothing.
    var hasDeniedPlayers: Bool { !deniedBundleIDs.isEmpty }

    func clearDenials() { deniedBundleIDs.removeAll() }

    // MARK: - Private

    private nonisolated func isRunning(_ player: ScriptablePlayer) -> Bool {
        !NSRunningApplication
            .runningApplications(withBundleIdentifier: player.bundleIdentifier)
            .isEmpty
    }

    /// Pull the OSA error number out of the error dictionary.
    ///
    /// Handled defensively because the value arrives as an `NSNumber` on some
    /// paths and a string on others, and a failed parse would silently disable
    /// the "automation was denied" handling — leaving Barakah re-prompting on
    /// every prayer instead of backing off once.
    static func errorNumber(from error: NSDictionary) -> Int {
        let raw = error[NSAppleScript.errorNumber]
        if let number = raw as? NSNumber { return number.intValue }
        if let text = raw as? String, let value = Int(text) { return value }
        return 0
    }

    /// Returns the script's string result, or nil if it failed for any reason.
    private func run(_ source: String, for player: ScriptablePlayer) -> String? {
        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)

        if let error {
            let code = Self.errorNumber(from: error)
            switch code {
            case Self.notAuthorizedCode:
                deniedBundleIDs.insert(player.bundleIdentifier)
                log.notice("automation denied for \(player.applicationName, privacy: .public)")
            case Self.notRunningCode:
                break
            default:
                log.debug("script failed for \(player.applicationName, privacy: .public): \(code)")
            }
            return nil
        }
        return result.stringValue ?? ""
    }
}
