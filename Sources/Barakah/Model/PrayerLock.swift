import Foundation

/// Whether a prayer locks the screen, and how many minutes after its athan.
///
/// Decoded by hand so a missing or malformed field falls back to its default
/// instead of failing the whole settings file — the same leniency as the Linux
/// build's `LockRule.from_json`.
public struct LockRule: Codable, Hashable, Sendable {
    /// Minutes after the athan before the screen is covered, unless changed.
    public static let defaultGraceMinutes = 15

    public var enabled: Bool
    public var graceMinutes: Int

    public init(enabled: Bool = true, graceMinutes: Int = LockRule.defaultGraceMinutes) {
        self.enabled = enabled
        self.graceMinutes = max(0, graceMinutes)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, graceMinutes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let enabled = (try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil
        let grace = (try? container.decodeIfPresent(Int.self, forKey: .graceMinutes)) ?? nil
        self.enabled = enabled ?? true
        self.graceMinutes = max(0, grace ?? LockRule.defaultGraceMinutes)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(graceMinutes, forKey: .graceMinutes)
    }
}

/// The prayer lock: once a prayer's grace period has passed, the screen is
/// covered until the user swears they prayed it or the prayer's time ends.
///
/// Stored in settings under its own optional key (`SettingsData.prayerLock`),
/// which a settings file from before the lock existed simply lacks. The JSON is
/// shared with the Linux build:
///
///     {"enabled": false, "rules": {"fajr": {"enabled": true, "graceMinutes": 15}, …}}
public struct PrayerLockSettings: Codable, Hashable, Sendable {
    public var enabled: Bool
    /// Keyed by the prayer's raw value rather than `PrayerKind`, so it always
    /// encodes as a JSON object whatever the encoder's dictionary strategy.
    public var rules: [String: LockRule]

    public init(enabled: Bool = false, rules: [PrayerKind: LockRule] = [:]) {
        self.enabled = enabled
        var all: [String: LockRule] = [:]
        for kind in PrayerKind.prayers {
            all[kind.rawValue] = rules[kind] ?? LockRule()
        }
        self.rules = all
    }

    public func rule(for kind: PrayerKind) -> LockRule {
        rules[kind.rawValue] ?? LockRule()
    }

    public mutating func setRule(_ rule: LockRule, for kind: PrayerKind) {
        rules[kind.rawValue] = rule
    }

    public mutating func updateRule(for kind: PrayerKind, _ mutate: (inout LockRule) -> Void) {
        var updated = self.rule(for: kind)
        mutate(&updated)
        rules[kind.rawValue] = updated
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, rules
    }

    /// Never throws: a lock section that is not an object, or rules that are
    /// missing or malformed, decode as the defaults. A throw here would fail
    /// the whole of `SettingsData`, and SettingsStore would set the user's
    /// settings aside as corrupt.
    public init(from decoder: Decoder) throws {
        var enabled = false
        var all: [String: LockRule] = [:]
        if let container = try? decoder.container(keyedBy: CodingKeys.self) {
            enabled = ((try? container.decodeIfPresent(Bool.self, forKey: .enabled)) ?? nil) ?? false
            let nested = try? container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .rules)
            for kind in PrayerKind.prayers {
                var decoded: LockRule?
                if let nested {
                    decoded = (try? nested.decodeIfPresent(LockRule.self, forKey: DynamicCodingKey(kind.rawValue))) ?? nil
                }
                all[kind.rawValue] = decoded ?? LockRule()
            }
        } else {
            for kind in PrayerKind.prayers {
                all[kind.rawValue] = LockRule()
            }
        }
        self.enabled = enabled
        self.rules = all
    }

    /// Exactly the five prayers, in the shape the Linux build writes.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        var out: [String: LockRule] = [:]
        for kind in PrayerKind.prayers {
            out[kind.rawValue] = rule(for: kind)
        }
        try container.encode(out, forKey: .rules)
    }
}

/// A coding key for keys that are only known at runtime: prayer names inside
/// the lock's rules, and days and prayers inside the prayer log.
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) {
        self.stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}
