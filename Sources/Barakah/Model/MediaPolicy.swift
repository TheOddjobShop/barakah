import Foundation

/// What Barakah does to whatever is playing when the adhan begins.
public enum MediaPauseMode: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Leave media alone.
    case off
    /// Send a real pause to whatever is playing, so it stops and stays stopped.
    case pause
    /// Pause, and additionally mute system output for the duration — belt and braces
    /// for players Barakah cannot reach (some web players, games, screen shares).
    case pauseAndMute

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .off: "Do nothing"
        case .pause: "Pause playback"
        case .pauseAndMute: "Pause and mute output"
        }
    }

    public var pausesPlayers: Bool { self != .off }
    public var mutesOutput: Bool { self == .pauseAndMute }
}

/// Whether — and when — playback that Barakah paused is resumed.
public enum MediaResumeMode: Codable, Hashable, Sendable {
    /// Never resume; the user picks their media back up themselves.
    case never
    /// Resume as soon as the adhan finishes or is stopped.
    case afterAthan
    /// Resume a set number of minutes after the adhan ends.
    case afterMinutes(Int)
    /// Resume once the iqama time passes (i.e. after the congregation has begun).
    case afterIqama

    public var label: String {
        switch self {
        case .never: "Don't resume"
        case .afterAthan: "When the athan ends"
        case .afterMinutes(let m): "\(m) minutes after the athan"
        case .afterIqama: "At iqama time"
        }
    }
}
