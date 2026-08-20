import Foundation

/// One prayer's resolved moments for a specific day.
public struct ScheduledPrayer: Identifiable, Hashable, Sendable {
    public let kind: PrayerKind
    /// Athan time, already adjusted by the per-prayer offset.
    public let athan: Date
    /// Iqama time, if the prayer has an iqama rule configured.
    public let iqama: Date?

    public var id: PrayerKind { kind }

    public init(kind: PrayerKind, athan: Date, iqama: Date?) {
        self.kind = kind
        self.athan = athan
        self.iqama = iqama
    }
}

/// A full day of prayer times for one place.
public struct DaySchedule: Sendable {
    /// Midnight (local to the place) of the day these times belong to.
    public let day: Date
    public let place: PlaceSetting
    public let prayers: [ScheduledPrayer]
    /// Midpoint of the night — the boundary many scholars give for Isha's window.
    public let middleOfTheNight: Date?
    /// Start of the last third of the night, for those praying qiyam.
    public let lastThirdOfTheNight: Date?

    public init(
        day: Date,
        place: PlaceSetting,
        prayers: [ScheduledPrayer],
        middleOfTheNight: Date? = nil,
        lastThirdOfTheNight: Date? = nil
    ) {
        self.day = day
        self.place = place
        self.prayers = prayers
        self.middleOfTheNight = middleOfTheNight
        self.lastThirdOfTheNight = lastThirdOfTheNight
    }

    public func prayer(_ kind: PrayerKind) -> ScheduledPrayer? {
        prayers.first { $0.kind == kind }
    }

    /// The next athan strictly after `date`, if it falls on this day.
    public func nextAthan(after date: Date) -> ScheduledPrayer? {
        prayers.first { $0.athan > date }
    }

    /// The prayer whose window contains `date` — the most recent athan at or
    /// before it. Nil before Fajr.
    public func currentPrayer(at date: Date) -> ScheduledPrayer? {
        prayers.last { $0.athan <= date }
    }
}

/// A single thing that will happen at a known moment. The scheduler works purely
/// in terms of these, which keeps "what fires when" independent of how it was
/// derived and trivially testable.
public struct PrayerEvent: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// The prayer time itself: play adhan, act on media.
        case athan
        /// A warning some minutes before iqama.
        case iqamaReminder(minutesBefore: Int)
        /// The iqama moment itself.
        case iqama
    }

    public let prayer: PrayerKind
    public let kind: Kind
    public let fireAt: Date

    public var id: String {
        switch kind {
        case .athan: "\(prayer.rawValue)-athan-\(fireAt.timeIntervalSince1970)"
        case .iqamaReminder(let m): "\(prayer.rawValue)-reminder\(m)-\(fireAt.timeIntervalSince1970)"
        case .iqama: "\(prayer.rawValue)-iqama-\(fireAt.timeIntervalSince1970)"
        }
    }

    public init(prayer: PrayerKind, kind: Kind, fireAt: Date) {
        self.prayer = prayer
        self.kind = kind
        self.fireAt = fireAt
    }
}
