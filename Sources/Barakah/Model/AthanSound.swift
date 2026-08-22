import Foundation

/// Which audio Barakah plays at athan time.
///
/// Barakah plays this itself through the audio engine rather than handing it to
/// Notification Center — user notification sounds are capped at 30 seconds and
/// cannot be stopped on demand, and a truncated adhan is worse than none.
public enum AthanSound: Codable, Hashable, Sendable {
    /// A short synthesised bell struck three times. Generated at runtime, so it
    /// always exists, weighs nothing, and carries no licensing question at all.
    case chime
    /// An adhan recording bundled with the app, addressed by resource name.
    case bundled(String)
    /// A file the user chose, addressed by security-scoped bookmark data so the
    /// grant survives relaunches and sandbox rules.
    case custom(bookmark: Data, displayName: String)
    /// Play nothing; visual notification only.
    case silent

    public var label: String {
        switch self {
        case .chime: "Chime (built in)"
        case .bundled(let name): AthanSound.bundledDisplayName(for: name)
        case .custom(_, let displayName): displayName
        case .silent: "Silent"
        }
    }

    public var isSilent: Bool {
        if case .silent = self { return true }
        return false
    }

    /// Resource name of the adhan shipped inside the app bundle.
    ///
    /// A user file of the same name in Application Support takes precedence, so
    /// anyone who prefers a different reciter can simply drop theirs in.
    public static let defaultBundledName = "Adhan"

    /// Human label for a bundled resource stem.
    public static func bundledDisplayName(for resource: String) -> String {
        resource
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .capitalized
    }
}
