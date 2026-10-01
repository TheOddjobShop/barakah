import Foundation

// The prayer log and the prayer lock's rule — tracker.py on Linux.
//
// Each prayer owns a window: from its athan to the next prayer's (Fajr's ends
// at sunrise, Isha's at the next Fajr). The log records what the user swore to
// for a window; a window that ends with nothing recorded was missed. Missed is
// never stored, only derived, so it is right whether or not the app was
// running when the window closed.
//
// The lock is derived the same way: it is due while a prayer's window is open,
// its grace period has passed, and the log has nothing for it. Nothing here
// fires; whoever asks gets the answer for that instant, so quitting the app or
// sleeping through the moment cannot skip it.
//
// Pure: no I/O. The log file itself is PrayerLogStore.

/// What a prayer's record says. The first three are what a user can record;
/// the rest are derived from the clock and never stored.
public enum PrayerStatus: String, Codable, CaseIterable, Hashable, Sendable {
    /// Prayed within its window.
    case prayed
    /// Made up after its window.
    case qada
    /// Not owed: travel combined, illness, haid.
    case excused
    /// The window ended with nothing recorded.
    case missed
    /// The window is open now.
    case open
    /// The window has not begun.
    case upcoming
    /// The window opened before tracking began.
    case untracked

    /// The statuses a user can record.
    public static let recordable: [PrayerStatus] = [.prayed, .qada, .excused]

    public var isRecordable: Bool { PrayerStatus.recordable.contains(self) }

    /// Days that count toward a streak: every prayer prayed on time, or not owed.
    public var keepsStreak: Bool { self == .prayed || self == .excused }

    public var label: String {
        switch self {
        case .prayed: return "Prayed on time"
        case .qada: return "Made up (qada)"
        case .excused: return "Excused"
        case .missed: return "Missed"
        case .open: return "Its time is now"
        case .upcoming: return "Not yet"
        case .untracked: return "Before tracking began"
        }
    }
}

// MARK: - The log

/// One record: what the user swore to, and when.
public struct PrayerLogEntry: Codable, Hashable, Sendable {
    public var status: PrayerStatus
    public var at: Date

    public init(status: PrayerStatus, at: Date) {
        self.status = status
        self.at = at
    }

    private enum CodingKeys: String, CodingKey {
        case status, at
    }

    /// Throws for anything but a recordable status, so the log can drop it.
    /// `at` is plain Unix seconds, as the Linux build writes it.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decode(String.self, forKey: .status)
        guard let status = PrayerStatus(rawValue: raw), status.isRecordable else {
            throw DecodingError.dataCorruptedError(
                forKey: .status, in: container, debugDescription: "unknown status \(raw)")
        }
        let seconds = try container.decodeIfPresent(Double.self, forKey: .at) ?? 0
        self.status = status
        self.at = Date(timeIntervalSince1970: seconds)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(status.rawValue, forKey: .status)
        try container.encode(at.timeIntervalSince1970, forKey: .at)
    }
}

/// Everything the user has recorded, by place-day and prayer.
///
/// Written to prayer-log.json in the same shape on both platforms:
///
///     {"version": 1, "since": 1781000000.0,
///      "days": {"2026-06-15": {"dhuhr": {"status": "prayed", "at": 1781550000.0}}}}
public struct PrayerLog: Codable, Hashable, Sendable {
    public static let version = 1

    /// When tracking began: a prayer whose window opened before it is neither
    /// prayed nor missed, so the first day is not a page of failures.
    public var since: Date
    /// "YYYY-MM-DD" in the place's time zone → prayer → record.
    public var days: [String: [PrayerKind: PrayerLogEntry]]

    public init(since: Date, days: [String: [PrayerKind: PrayerLogEntry]] = [:]) {
        self.since = since
        self.days = days
    }

    public func entry(day: String, kind: PrayerKind) -> PrayerLogEntry? {
        days[day]?[kind]
    }

    /// Only the recordable statuses are stored; anything else is ignored.
    public mutating func record(day: String, kind: PrayerKind, status: PrayerStatus, at: Date) {
        guard status.isRecordable, kind.isPrayer else {
            assertionFailure("cannot record \(status.rawValue) for \(kind.rawValue)")
            return
        }
        var entries = days[day] ?? [:]
        entries[kind] = PrayerLogEntry(status: status, at: at)
        days[day] = entries
    }

    public mutating func clear(day: String, kind: PrayerKind) {
        guard var entries = days[day] else { return }
        entries[kind] = nil
        days[day] = entries.isEmpty ? nil : entries
    }

    /// The day key a log uses: the calendar day in `timeZone`.
    public static func dayKey(_ date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    // MARK: Codable

    private enum CodingKeys: String, CodingKey {
        case version, since, days
    }

    /// Lenient below the top level, like the Linux build: a day that is not an
    /// object, a key that is not a prayer (such as "sunrise") and an entry with
    /// an unknown status are dropped rather than failing the whole log.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let seconds = try container.decodeIfPresent(Double.self, forKey: .since) ?? 0
        var days: [String: [PrayerKind: PrayerLogEntry]] = [:]
        if let raw = try? container.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: .days) {
            for dayKey in raw.allKeys {
                guard let prayers = try? raw.nestedContainer(keyedBy: DynamicCodingKey.self, forKey: dayKey) else {
                    continue
                }
                var entries: [PrayerKind: PrayerLogEntry] = [:]
                for prayerKey in prayers.allKeys {
                    guard let kind = PrayerKind(rawValue: prayerKey.stringValue), kind.isPrayer,
                          let entry = try? prayers.decode(PrayerLogEntry.self, forKey: prayerKey) else {
                        continue
                    }
                    entries[kind] = entry
                }
                if !entries.isEmpty {
                    days[dayKey.stringValue] = entries
                }
            }
        }
        self.since = Date(timeIntervalSince1970: seconds)
        self.days = days
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(PrayerLog.version, forKey: .version)
        try container.encode(since.timeIntervalSince1970, forKey: .since)
        var out: [String: [String: PrayerLogEntry]] = [:]
        for (day, entries) in days {
            var prayers: [String: PrayerLogEntry] = [:]
            for (kind, entry) in entries {
                prayers[kind.rawValue] = entry
            }
            out[day] = prayers
        }
        try container.encode(out, forKey: .days)
    }
}

// MARK: - Windows, statuses and the lock

/// One prayer's time on one place-day.
public struct PrayerWindow: Hashable, Sendable, Identifiable {
    public let kind: PrayerKind
    /// The place-day the prayer belongs to, "YYYY-MM-DD".
    public let day: String
    /// The athan, with its fine adjustment.
    public let start: Date
    /// The next window's start; sunrise for Fajr, the next Fajr for Isha.
    public let end: Date
    public let iqama: Date?

    public var id: String { "\(day)-\(kind.rawValue)" }

    public init(kind: PrayerKind, day: String, start: Date, end: Date, iqama: Date? = nil) {
        self.kind = kind
        self.day = day
        self.start = start
        self.end = end
        self.iqama = iqama
    }

    public func contains(_ date: Date) -> Bool {
        start <= date && date < end
    }
}

/// `active` is the window the screen is locked for, if any. `nextAt` is when
/// the next lock would begin if nothing is logged before then — for a
/// countdown, and for nothing else.
public struct LockState: Hashable, Sendable {
    public var active: PrayerWindow?
    public var nextAt: Date?
    public var nextWindow: PrayerWindow?

    public init(active: PrayerWindow? = nil, nextAt: Date? = nil, nextWindow: PrayerWindow? = nil) {
        self.active = active
        self.nextAt = nextAt
        self.nextWindow = nextWindow
    }
}

/// One place-day of the tracker, each prayer with its status.
public struct DayRecord: Hashable, Sendable, Identifiable {
    public let day: String
    public let statuses: [PrayerKind: PrayerStatus]

    public var id: String { day }

    public init(day: String, statuses: [PrayerKind: PrayerStatus]) {
        self.day = day
        self.statuses = statuses
    }
}

/// Windows, statuses, the lock and history, derived from settings, the log and
/// a moment. Mirrors tracker.py function for function.
public enum PrayerTracker {

    /// Sunrise ends Fajr whether or not the list shows it, and the engine
    /// leaves it out when it is hidden.
    static func boundaries(_ settings: SettingsData) -> SettingsData {
        if settings.showSunrise { return settings }
        var copy = settings
        copy.showSunrise = true
        return copy
    }

    static func placeCalendar(_ settings: SettingsData) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = settings.activePlace.timeZone
        return calendar
    }

    /// The five windows of the place-day containing `day`, in order.
    public static func windows(
        for day: Date,
        settings: SettingsData,
        engine: PrayerTimeEngine = PrayerTimeEngine()
    ) -> [PrayerWindow] {
        let settings = boundaries(settings)
        let calendar = placeCalendar(settings)
        guard let today = engine.schedule(for: day, settings: settings) else { return [] }
        var tomorrow: DaySchedule?
        if let next = calendar.date(byAdding: .day, value: 1, to: today.day) {
            tomorrow = engine.schedule(for: next, settings: settings)
        }
        let marks = today.prayers
        let following = tomorrow?.prayer(.fajr)
        let key = PrayerLog.dayKey(today.day, in: calendar.timeZone)

        var out: [PrayerWindow] = []
        for (index, prayer) in marks.enumerated() where prayer.kind.isPrayer {
            let boundary: ScheduledPrayer? = index + 1 < marks.count ? marks[index + 1] : following
            guard let end = boundary?.athan else { continue }
            out.append(PrayerWindow(
                kind: prayer.kind, day: key, start: prayer.athan, end: end, iqama: prayer.iqama))
        }
        return out
    }

    /// The prayer whose time it is: yesterday's Isha before Fajr, nothing
    /// between sunrise and Dhuhr.
    public static func window(
        at now: Date,
        settings: SettingsData,
        engine: PrayerTimeEngine = PrayerTimeEngine()
    ) -> PrayerWindow? {
        let calendar = placeCalendar(settings)
        var days = [now]
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) {
            days.append(yesterday)
        }
        for day in days {
            for window in windows(for: day, settings: settings, engine: engine) where window.contains(now) {
                return window
            }
        }
        return nil
    }

    public static func status(of window: PrayerWindow, in log: PrayerLog, now: Date) -> PrayerStatus {
        if let entry = log.entry(day: window.day, kind: window.kind) { return entry.status }
        if window.start < log.since { return .untracked }
        if now < window.start { return .upcoming }
        if now < window.end { return .open }
        return .missed
    }

    /// What "I prayed it" means right now: on time inside the window, qada after.
    public static func statusForRecord(_ window: PrayerWindow, now: Date) -> PrayerStatus {
        now < window.end ? .prayed : .qada
    }

    public static func lockState(
        now: Date,
        settings: SettingsData,
        log: PrayerLog,
        engine: PrayerTimeEngine = PrayerTimeEngine()
    ) -> LockState {
        let lock = settings.lock
        guard lock.enabled else { return LockState() }
        let calendar = placeCalendar(settings)
        let today = calendar.startOfDay(for: now)

        var days: [Date] = []
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today) { days.append(yesterday) }
        days.append(now)
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) { days.append(tomorrow) }

        var active: PrayerWindow?
        var nextAt: Date?
        var nextWindow: PrayerWindow?
        for day in days {
            for window in windows(for: day, settings: settings, engine: engine) {
                let rule = lock.rule(for: window.kind)
                if !rule.enabled || window.start < log.since
                    || log.entry(day: window.day, kind: window.kind) != nil {
                    continue
                }
                // In floating point so an absurd grace from a hand-edited file
                // cannot overflow.
                let locksAt = window.start.addingTimeInterval(Double(rule.graceMinutes) * 60)
                if locksAt >= window.end { continue }
                if locksAt <= now && now < window.end {
                    active = window
                } else if locksAt > now {
                    if let earliest = nextAt, earliest <= locksAt { continue }
                    nextAt = locksAt
                    nextWindow = window
                }
            }
        }
        return LockState(active: active, nextAt: nextAt, nextWindow: nextWindow)
    }

    // MARK: History

    /// The last `days` place-days, newest first, each prayer with its status.
    ///
    /// A year of this backs the heatmap, so days whose every window has ended
    /// — everything before yesterday — are settled from the log alone: their
    /// prayers were missed unless recorded, or untracked if the day ended
    /// before tracking began. Only the day tracking began on, yesterday and
    /// today need their prayer times.
    public static func history(
        log: PrayerLog,
        settings: SettingsData,
        now: Date,
        days: Int,
        engine: PrayerTimeEngine = PrayerTimeEngine()
    ) -> [DayRecord] {
        let calendar = placeCalendar(settings)
        let today = calendar.startOfDay(for: now)
        var out: [DayRecord] = []
        out.reserveCapacity(max(0, days))
        for offset in 0..<max(0, days) {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = PrayerLog.dayKey(day, in: calendar.timeZone)
            if let derived = settled(day, since: log.since, now: now, calendar: calendar) {
                var statuses: [PrayerKind: PrayerStatus] = [:]
                for kind in PrayerKind.prayers {
                    statuses[kind] = log.entry(day: key, kind: kind)?.status ?? derived
                }
                out.append(DayRecord(day: key, statuses: statuses))
                continue
            }
            var found: [PrayerKind: PrayerWindow] = [:]
            for window in windows(for: day, settings: settings, engine: engine) {
                found[window.kind] = window
            }
            var statuses: [PrayerKind: PrayerStatus] = [:]
            for kind in PrayerKind.prayers {
                if let window = found[kind] {
                    statuses[kind] = status(of: window, in: log, now: now)
                } else {
                    statuses[kind] = log.entry(day: key, kind: kind)?.status ?? .untracked
                }
            }
            out.append(DayRecord(day: key, statuses: statuses))
        }
        return out
    }

    /// What an unrecorded prayer of `day` (the start of a place-day) is
    /// without computing its times, if that can be known: every window of a
    /// day has ended by the start of the day after next, since Isha ends at
    /// the next Fajr. Nil means compute it.
    static func settled(_ day: Date, since: Date, now: Date, calendar: Calendar) -> PrayerStatus? {
        guard let dayAfterNext = calendar.date(byAdding: .day, value: 2, to: day),
              let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
        if dayAfterNext > now { return nil }
        if nextDay <= since { return .untracked }
        if day >= since { return .missed }
        // Tracking began during this day.
        return nil
    }

    // MARK: Heat

    /// The darkest heat level; a day's level runs from 0 to this.
    public static let heatLevels = 4

    /// How much of a day was kept, for the heatmap: prayers on time and
    /// prayers not owed count whole, a prayer made up later counts half.
    public struct Heat: Hashable, Sendable {
        /// 0 to 5.
        public let score: Double
        /// 0 (nothing kept) to `heatLevels` (all five on time or not owed).
        public let level: Int
        public let onTime: Int
        public let madeUp: Int
        public let excused: Int
        public let missed: Int
    }

    /// Nil for a day with nothing tracked.
    public static func heat(_ record: DayRecord) -> Heat? {
        let values = Array(record.statuses.values)
        if values.allSatisfy({ $0 == .untracked }) { return nil }
        let onTime = values.filter { $0 == .prayed }.count
        let madeUp = values.filter { $0 == .qada }.count
        let excused = values.filter { $0 == .excused }.count
        let missed = values.filter { $0 == .missed }.count
        let score = Double(onTime + excused) + Double(madeUp) / 2
        let level: Int
        if score <= 0 {
            level = 0
        } else if score <= 2 {
            level = 1
        } else if score <= 3.5 {
            level = 2
        } else if score < Double(PrayerKind.prayers.count) {
            level = 3
        } else {
            level = heatLevels
        }
        return Heat(score: score, level: level, onTime: onTime, madeUp: madeUp, excused: excused, missed: missed)
    }

    /// "4 of 5 on time · 1 made up", as the heatmap's tooltip says it. `today`
    /// adds "so far" while some of the day's prayers are still to come.
    public static func describe(_ record: DayRecord, today: Bool = false) -> String {
        guard let found = heat(record) else { return "Before tracking began" }
        let total = record.statuses.count
        var parts: [String] = []
        if found.onTime == total {
            parts.append("All five on time")
        } else {
            parts.append("\(found.onTime) of \(total) on time")
        }
        if found.madeUp > 0 { parts.append("\(found.madeUp) made up") }
        if found.excused > 0 { parts.append("\(found.excused) excused") }
        if found.missed > 0 { parts.append("\(found.missed) missed") }
        if today && found.onTime + found.madeUp + found.excused + found.missed < total {
            parts.append("so far")
        }
        return parts.joined(separator: " · ")
    }

    /// "1,243 prayers on time in the last year".
    public static func yearFooter(_ records: [DayRecord]) -> String {
        var onTime = 0
        for record in records {
            for value in record.statuses.values where value == .prayed {
                onTime += 1
            }
        }
        return "\(grouped(onTime)) prayer\(onTime == 1 ? "" : "s") on time in the last year"
    }

    /// Thousands separated by commas whatever the locale, as Linux's "{:,}".
    static func grouped(_ value: Int) -> String {
        let digits = Array(String(value.magnitude))
        var out = ""
        for (index, digit) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 {
                out.append(",")
            }
            out.append(digit)
        }
        return value < 0 ? "-" + out : out
    }

    // MARK: Streaks and ratios

    /// Consecutive complete days, newest first. Today counts once it is
    /// complete, and does not break the streak while it is still under way.
    public static func streak(_ records: [DayRecord]) -> Int {
        var count = 0
        for (index, record) in records.enumerated() {
            let values = Array(record.statuses.values)
            if values.allSatisfy({ $0.keepsStreak }) {
                count += 1
                continue
            }
            if index == 0 && values.allSatisfy({ $0.keepsStreak || $0 == .open || $0 == .upcoming }) {
                continue
            }
            break
        }
        return count
    }

    /// The longest run of complete days anywhere in the records.
    public static func longestStreak(_ records: [DayRecord]) -> Int {
        var best = 0
        var run = 0
        for record in records {
            if record.statuses.values.allSatisfy({ $0.keepsStreak }) {
                run += 1
                best = max(best, run)
            } else {
                run = 0
            }
        }
        return best
    }

    /// Prayed on time over prayers owed, across the records; nil if none were owed.
    public static func onTimeRatio(_ records: [DayRecord]) -> Double? {
        var owed = 0
        var prayed = 0
        for record in records {
            for value in record.statuses.values where value == .prayed || value == .qada || value == .missed {
                owed += 1
                if value == .prayed { prayed += 1 }
            }
        }
        return owed > 0 ? Double(prayed) / Double(owed) : nil
    }
}
