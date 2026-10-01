import Testing
import Foundation
@testable import Barakah

// The prayer log, prayer windows, and when the prayer lock is due — a port of
// linux/tests/test_tracker.py, case for case, on the same place and day.

private let losAngeles = PlaceSetting(
    name: "Los Angeles", latitude: 34.0522, longitude: -118.2437,
    timeZoneIdentifier: "America/Los_Angeles")

private func lockSettings(
    lock: Bool = true,
    showSunrise: Bool = true,
    rules: [PrayerKind: LockRule] = [:]
) -> SettingsData {
    var settings = SettingsData()
    settings.locationMode = .manual
    settings.manualPlace = losAngeles
    settings.showSunrise = showSunrise
    if lock {
        var prayerLock = PrayerLockSettings(enabled: true)
        for (kind, rule) in rules {
            prayerLock.setRule(rule, for: kind)
        }
        settings.prayerLock = prayerLock
    }
    return settings
}

/// A wall-clock time in Los Angeles on June `day`, 2026.
private func at(_ hour: Int, _ minute: Int = 0, day: Int = 15) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = losAngeles.timeZone
    return calendar.date(from: DateComponents(year: 2026, month: 6, day: day, hour: hour, minute: minute))!
}

private func todaysDhuhr() throws -> PrayerWindow {
    let found = PrayerTracker.windows(for: at(12), settings: lockSettings())
    try #require(found.count == 5)
    return found[1]
}

private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("barakah-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("Prayer windows")
struct PrayerWindowTests {

    @Test("The five windows chain into each other")
    func fiveWindowsChain() {
        let found = PrayerTracker.windows(for: at(12), settings: lockSettings())
        #expect(found.map(\.kind) == [.fajr, .dhuhr, .asr, .maghrib, .isha])
        #expect(found.allSatisfy { $0.day == "2026-06-15" })
        for (earlier, later) in zip(found.dropFirst(), found.dropFirst(2)) {
            #expect(earlier.end == later.start)
        }
    }

    @Test("Fajr ends at sunrise even when sunrise is hidden")
    func fajrEndsAtSunrise() throws {
        let shown = try #require(PrayerTracker.windows(for: at(12), settings: lockSettings(showSunrise: true)).first)
        let hidden = try #require(PrayerTracker.windows(for: at(12), settings: lockSettings(showSunrise: false)).first)
        #expect(shown == hidden)
        let dhuhr = try todaysDhuhr()
        #expect(hidden.end < dhuhr.start, "Fajr must end at sunrise, not run on to Dhuhr")
    }

    @Test("Isha runs to the next Fajr")
    func ishaRunsToNextFajr() throws {
        let isha = try #require(PrayerTracker.windows(for: at(12), settings: lockSettings()).last)
        let nextFajr = try #require(PrayerTracker.windows(for: at(12, day: 16), settings: lockSettings()).first)
        #expect(isha.end == nextFajr.start)
    }

    @Test("Before Fajr it is still yesterday's Isha")
    func beforeFajrIsYesterdaysIsha() throws {
        let window = try #require(PrayerTracker.window(at: at(2, day: 16), settings: lockSettings()))
        #expect(window.kind == .isha)
        #expect(window.day == "2026-06-15")
    }

    @Test("Between sunrise and Dhuhr is no prayer's time")
    func betweenSunriseAndDhuhr() {
        #expect(PrayerTracker.window(at: at(9), settings: lockSettings()) == nil)
    }
}

@Suite("Prayer statuses")
struct PrayerStatusTests {

    @Test("Upcoming, open and missed are derived from the clock")
    func derivedStatuses() throws {
        let dhuhr = try todaysDhuhr()
        let log = PrayerLog(since: at(0))
        #expect(PrayerTracker.status(of: dhuhr, in: log, now: dhuhr.start.addingTimeInterval(-60)) == .upcoming)
        #expect(PrayerTracker.status(of: dhuhr, in: log, now: dhuhr.start.addingTimeInterval(60)) == .open)
        #expect(PrayerTracker.status(of: dhuhr, in: log, now: dhuhr.end.addingTimeInterval(60)) == .missed)
    }

    @Test("Prayers before tracking began are untracked, not missed")
    func beforeTrackingIsUntracked() throws {
        let dhuhr = try todaysDhuhr()
        let log = PrayerLog(since: dhuhr.start.addingTimeInterval(1))
        #expect(PrayerTracker.status(of: dhuhr, in: log, now: dhuhr.end.addingTimeInterval(60)) == .untracked)
    }

    @Test("A recorded status wins over the clock")
    func recordedStatusWins() throws {
        let dhuhr = try todaysDhuhr()
        var log = PrayerLog(since: at(0))
        log.record(day: dhuhr.day, kind: .dhuhr, status: .qada, at: dhuhr.end.addingTimeInterval(60))
        #expect(PrayerTracker.status(of: dhuhr, in: log, now: dhuhr.end.addingTimeInterval(120)) == .qada)
    }

    @Test("An oath after the window is qada")
    func oathAfterWindowIsQada() throws {
        let dhuhr = try todaysDhuhr()
        #expect(PrayerTracker.statusForRecord(dhuhr, now: dhuhr.end.addingTimeInterval(-1)) == .prayed)
        #expect(PrayerTracker.statusForRecord(dhuhr, now: dhuhr.end) == .qada)
    }
}

@Suite("Prayer lock")
struct PrayerLockTests {

    private func state(_ now: Date, _ settings: SettingsData = lockSettings(), log: PrayerLog) -> LockState {
        PrayerTracker.lockState(now: now, settings: settings, log: log)
    }

    @Test("Off by default, and absent from a fresh settings value")
    func offByDefault() throws {
        let dhuhr = try todaysDhuhr()
        #expect(SettingsData().prayerLock == nil)
        #expect(!SettingsData().lock.enabled)
        let log = PrayerLog(since: at(0))
        #expect(state(dhuhr.start.addingTimeInterval(3600), lockSettings(lock: false), log: log).active == nil)
    }

    @Test("Locks once the grace period has passed")
    func locksAfterGrace() throws {
        let dhuhr = try todaysDhuhr()
        let log = PrayerLog(since: at(0))
        let grace: TimeInterval = 15 * 60
        let before = state(dhuhr.start.addingTimeInterval(grace - 1), log: log)
        #expect(before.active == nil)
        #expect(before.nextAt == dhuhr.start.addingTimeInterval(grace))
        #expect(state(dhuhr.start.addingTimeInterval(grace), log: log).active == dhuhr)
    }

    @Test("An oath releases it")
    func oathReleases() throws {
        let dhuhr = try todaysDhuhr()
        var log = PrayerLog(since: at(0))
        log.record(day: dhuhr.day, kind: .dhuhr, status: .prayed, at: dhuhr.start.addingTimeInterval(600))
        #expect(state(dhuhr.start.addingTimeInterval(3600), log: log).active == nil)
    }

    @Test("Praying before the grace period ends prevents it")
    func prayingEarlyPrevents() throws {
        let dhuhr = try todaysDhuhr()
        var log = PrayerLog(since: at(0))
        log.record(day: dhuhr.day, kind: .dhuhr, status: .prayed, at: dhuhr.start.addingTimeInterval(60))
        let lock = state(dhuhr.start.addingTimeInterval(120), log: log)
        #expect(lock.active == nil)
        #expect(lock.nextWindow?.kind == .asr)
    }

    @Test("It ends with the window")
    func endsWithWindow() throws {
        let dhuhr = try todaysDhuhr()
        let log = PrayerLog(since: at(0))
        #expect(state(dhuhr.end.addingTimeInterval(-1), log: log).active == dhuhr)
        #expect(state(dhuhr.end.addingTimeInterval(1), log: log).active == nil)
    }

    @Test("A disabled prayer never locks")
    func disabledPrayerNeverLocks() throws {
        let dhuhr = try todaysDhuhr()
        let settings = lockSettings(rules: [.dhuhr: LockRule(enabled: false)])
        #expect(state(dhuhr.start.addingTimeInterval(3600), settings, log: PrayerLog(since: at(0))).active == nil)
    }

    @Test("A grace longer than the window never locks")
    func graceLongerThanWindow() throws {
        let dhuhr = try todaysDhuhr()
        let settings = lockSettings(rules: [.dhuhr: LockRule(graceMinutes: 24 * 60)])
        #expect(state(dhuhr.start.addingTimeInterval(3600), settings, log: PrayerLog(since: at(0))).active == nil)
    }

    @Test("Isha still locks after midnight")
    func ishaLocksAfterMidnight() throws {
        let active = try #require(state(at(1, day: 16), log: PrayerLog(since: at(0))).active)
        #expect(active.kind == .isha)
        #expect(active.day == "2026-06-15")
    }

    @Test("Nothing before tracking began locks")
    func nothingBeforeTrackingLocks() throws {
        let dhuhr = try todaysDhuhr()
        let log = PrayerLog(since: dhuhr.start.addingTimeInterval(1))
        #expect(state(dhuhr.start.addingTimeInterval(3600), log: log).active == nil)
    }

    @Test("Muting is not the lock's business: the lock ignores athan settings")
    func lockIgnoresAthanSettings() throws {
        let dhuhr = try todaysDhuhr()
        var settings = lockSettings()
        settings.prayerConfigs[.dhuhr]?.athanEnabled = false
        #expect(state(dhuhr.start.addingTimeInterval(3600), settings, log: PrayerLog(since: at(0))).active == dhuhr)
    }
}

@Suite("Prayer history")
struct PrayerHistoryTests {

    private static let full: [PrayerKind: PrayerStatus] =
        Dictionary(uniqueKeysWithValues: PrayerKind.prayers.map { ($0, PrayerStatus.prayed) })

    private func with(_ changes: [PrayerKind: PrayerStatus],
                      base: [PrayerKind: PrayerStatus] = PrayerHistoryTests.full) -> [PrayerKind: PrayerStatus] {
        base.merging(changes) { _, new in new }
    }

    @Test("The streak counts complete days and spares today")
    func streakSparesToday() {
        let full = PrayerHistoryTests.full
        let today = with([.maghrib: .open, .isha: .upcoming])
        let records = [
            DayRecord(day: "d0", statuses: today),
            DayRecord(day: "d1", statuses: full),
            DayRecord(day: "d2", statuses: with([.asr: .excused])),
            DayRecord(day: "d3", statuses: with([.fajr: .missed])),
            DayRecord(day: "d4", statuses: full),
        ]
        #expect(PrayerTracker.streak(records) == 2)
        let older = Array(records.dropFirst())
        #expect(PrayerTracker.streak([DayRecord(day: "d0", statuses: full)] + older) == 3)
        #expect(PrayerTracker.streak(
            [DayRecord(day: "d0", statuses: with([.fajr: .missed], base: today))] + older) == 0)
    }

    @Test("The on-time ratio ignores what is not yet owed")
    func ratioIgnoresUnowed() throws {
        let records = [DayRecord(day: "d0", statuses: [
            .fajr: .prayed, .dhuhr: .qada, .asr: .missed, .maghrib: .open, .isha: .untracked,
        ])]
        let ratio = try #require(PrayerTracker.onTimeRatio(records))
        #expect(abs(ratio - 1.0 / 3.0) < 1e-9)
        #expect(PrayerTracker.onTimeRatio([DayRecord(day: "d0", statuses: [.fajr: .upcoming])]) == nil)
    }

    @Test("History is newest first")
    func historyNewestFirst() throws {
        var log = PrayerLog(since: at(0, day: 14))
        log.record(day: "2026-06-14", kind: .fajr, status: .prayed, at: at(5, day: 14))
        let records = PrayerTracker.history(log: log, settings: lockSettings(), now: at(12), days: 3)
        #expect(records.map(\.day) == ["2026-06-15", "2026-06-14", "2026-06-13"])
        try #require(records.count == 3)
        #expect(records[1].statuses[.fajr] == .prayed)
        #expect(records[1].statuses[.dhuhr] == .missed)
        #expect(records[2].statuses[.fajr] == .untracked)
        #expect(records[0].statuses[.isha] == .upcoming)
    }
}

@Suite("A year of prayer")
struct PrayerYearTests {

    private static let fivePrayed: [PrayerKind: PrayerStatus] =
        Dictionary(uniqueKeysWithValues: PrayerKind.prayers.map { ($0, PrayerStatus.prayed) })

    /// Every prayer missed, then `changes`.
    private func day(_ changes: [PrayerKind: PrayerStatus] = [:]) -> DayRecord {
        var statuses = Dictionary(uniqueKeysWithValues: PrayerKind.prayers.map { ($0, PrayerStatus.missed) })
        statuses.merge(changes) { _, new in new }
        return DayRecord(day: "d", statuses: statuses)
    }

    @Test("Settled days agree with computing every window")
    func settledDaysAgree() throws {
        let engine = PrayerTimeEngine()
        let settings = lockSettings()
        let now = at(12, day: 20)
        var log = PrayerLog(since: at(15, day: 10))  // tracking began mid-afternoon
        let epoch = Date(timeIntervalSince1970: 0)
        log.record(day: "2026-06-12", kind: .asr, status: .prayed, at: epoch)
        log.record(day: "2026-06-09", kind: .fajr, status: .qada, at: epoch)
        log.record(day: "2026-06-19", kind: .isha, status: .excused, at: epoch)

        let fast = PrayerTracker.history(log: log, settings: settings, now: now, days: 14, engine: engine)
        try #require(fast.count == 14)
        for record in fast {
            let parts = record.day.split(separator: "-").compactMap { Int($0) }
            try #require(parts.count == 3)
            try #require(parts[1] == 6, "every day shown is in June 2026")
            var slow: [PrayerKind: PrayerStatus] = [:]
            for window in PrayerTracker.windows(for: at(12, day: parts[2]), settings: settings, engine: engine) {
                slow[window.kind] = PrayerTracker.status(of: window, in: log, now: now)
            }
            #expect(record.statuses == slow, "\(record.day)")
        }
        #expect(fast[10].day == "2026-06-10")
        #expect(fast[10].statuses[.dhuhr] == .untracked, "June 10, before tracking began")
        #expect(fast[10].statuses[.maghrib] == .missed, "June 10, after it began")
    }

    @Test("A year of history is cheap")
    func yearIsCheap() {
        let log = PrayerLog(since: at(0, day: 1).addingTimeInterval(-400 * 86_400))
        let started = Date()
        let records = PrayerTracker.history(log: log, settings: lockSettings(), now: at(12), days: 371)
        let elapsed = Date().timeIntervalSince(started)
        #expect(records.count == 371)
        #expect(elapsed < 0.5)
    }

    @Test("Heat counts kept prayers")
    func heatCountsKeptPrayers() throws {
        #expect(PrayerTracker.heat(DayRecord(day: "d", statuses: [.fajr: .untracked, .dhuhr: .untracked])) == nil)
        #expect(PrayerTracker.heat(day())?.level == 0)
        #expect(PrayerTracker.heat(day([.fajr: .prayed, .dhuhr: .qada]))?.level == 1)                  // 1.5
        #expect(PrayerTracker.heat(day([.fajr: .prayed, .dhuhr: .prayed, .asr: .excused]))?.level == 2) // 3
        #expect(PrayerTracker.heat(day([
            .fajr: .prayed, .dhuhr: .prayed, .asr: .prayed, .maghrib: .prayed, .isha: .qada,
        ]))?.level == 3)
        let full = try #require(PrayerTracker.heat(day([
            .fajr: .prayed, .dhuhr: .prayed, .asr: .prayed, .maghrib: .excused, .isha: .prayed,
        ])))
        #expect(full.level == 4)
        #expect(full.onTime == 4)
        #expect(full.excused == 1)
        #expect(full.missed == 0)
    }

    @Test("The longest streak")
    func longestStreak() {
        let full = PrayerYearTests.fivePrayed
        var broken = full
        broken[.asr] = .missed
        let records = [broken, full, full, broken, full, full, full, broken].enumerated().map {
            DayRecord(day: String($0.offset), statuses: $0.element)
        }
        #expect(PrayerTracker.longestStreak(records) == 3)
    }

    @Test("A day is described as the heatmap's tooltip says it")
    func describeDay() {
        #expect(PrayerTracker.describe(DayRecord(day: "d", statuses: PrayerYearTests.fivePrayed)) == "All five on time")
        #expect(PrayerTracker.describe(DayRecord(day: "d", statuses: [.fajr: .untracked])) == "Before tracking began")
        #expect(PrayerTracker.describe(day([.fajr: .prayed, .dhuhr: .qada, .asr: .excused]))
                == "1 of 5 on time · 1 made up · 1 excused · 2 missed")
        let today = DayRecord(day: "d", statuses: [
            .fajr: .prayed, .dhuhr: .prayed, .asr: .open, .maghrib: .upcoming, .isha: .upcoming,
        ])
        #expect(PrayerTracker.describe(today, today: true) == "2 of 5 on time · so far")
        #expect(PrayerTracker.describe(today) == "2 of 5 on time")
    }

    @Test("The year's footer counts prayers on time, with thousands separated")
    func yearFooter() {
        let one = [day([.fajr: .prayed])]
        #expect(PrayerTracker.yearFooter(one) == "1 prayer on time in the last year")
        let many = Array(repeating: DayRecord(day: "d", statuses: PrayerYearTests.fivePrayed), count: 250)
        #expect(PrayerTracker.yearFooter(many) == "1,250 prayers on time in the last year")
        #expect(PrayerTracker.yearFooter([]) == "0 prayers on time in the last year")
        #expect(PrayerTracker.grouped(1_234_567) == "1,234,567")
        #expect(PrayerTracker.grouped(999) == "999")
    }
}

@Suite("Prayer lock and log persistence")
@MainActor
struct PrayerLogPersistenceTests {

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        let raw = try JSONSerialization.jsonObject(with: data)
        return try #require(raw as? [String: Any])
    }

    @Test("Lock settings round-trip, and stay absent until set")
    func settingsRoundTrip() throws {
        let fresh = try jsonObject(JSONEncoder().encode(SettingsData()))
        #expect(!fresh.keys.contains("prayerLock"),
                "a fresh settings file must not carry the key — Linux parity relies on it")

        let settings = lockSettings(rules: [.dhuhr: LockRule(enabled: true, graceMinutes: 40)])
        let encoded = try JSONEncoder().encode(settings)
        let back = try JSONDecoder().decode(SettingsData.self, from: encoded)
        #expect(back.lock.enabled)
        #expect(back.lock.rule(for: .dhuhr) == LockRule(enabled: true, graceMinutes: 40))
        #expect(back.lock.rule(for: .isha) == LockRule())

        // The shape the Linux build reads: an object keyed by the five prayers.
        let object = try jsonObject(encoded)
        let lock = try #require(object["prayerLock"] as? [String: Any])
        let rules = try #require(lock["rules"] as? [String: Any])
        #expect(Set(rules.keys) == Set(PrayerKind.prayers.map(\.rawValue)))
        let dhuhr = try #require(rules["dhuhr"] as? [String: Any])
        #expect(dhuhr["graceMinutes"] as? Int == 40)
        #expect(dhuhr["enabled"] as? Bool == true)
    }

    @Test("A settings file from before the lock still decodes")
    func oldSettingsStillDecode() throws {
        var object = try jsonObject(JSONEncoder().encode(SettingsData()))
        object["prayerLock"] = nil
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SettingsData.self, from: data)
        #expect(decoded.prayerLock == nil)
        #expect(!decoded.lock.enabled)
    }

    @Test("The desktop widget setting stays absent until set, and round-trips")
    func widgetSettingRoundTrip() throws {
        let fresh = try jsonObject(JSONEncoder().encode(SettingsData()))
        #expect(!fresh.keys.contains("trackerWidget"),
                "a fresh settings file must not carry the key — Linux parity relies on it")
        #expect(SettingsData().trackerWidget == nil)
        #expect(!SettingsData().widget.enabled)

        var settings = SettingsData()
        settings.updateWidget { $0.enabled = true }
        let encoded = try JSONEncoder().encode(settings)
        let object = try jsonObject(encoded)
        let widget = try #require(object["trackerWidget"] as? [String: Any])
        #expect(widget["enabled"] as? Bool == true)
        #expect(Set(widget.keys) == Set(["enabled"]), "the shape the Linux build writes")
        let back = try JSONDecoder().decode(SettingsData.self, from: encoded)
        #expect(back.widget.enabled)

        // A malformed section is the default, not a corrupt settings file.
        var junk = fresh
        junk["trackerWidget"] = "junk"
        let decoded = try JSONDecoder().decode(
            SettingsData.self, from: JSONSerialization.data(withJSONObject: junk))
        #expect(!decoded.widget.enabled)
    }

    @Test("Missing and malformed lock fields fall back to their defaults")
    func lenientLockDecoding() throws {
        var object = try jsonObject(JSONEncoder().encode(SettingsData()))
        let rules: [String: Any] = [
            "asr": ["graceMinutes": -5] as [String: Any],
            "maghrib": "junk",
            "sunrise": ["enabled": false] as [String: Any],
        ]
        let lock: [String: Any] = ["enabled": true, "rules": rules]
        object["prayerLock"] = lock
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(SettingsData.self, from: data)
        #expect(decoded.lock.enabled)
        #expect(decoded.lock.rule(for: .asr) == LockRule(enabled: true, graceMinutes: 0))
        #expect(decoded.lock.rule(for: .maghrib) == LockRule())
        #expect(decoded.lock.rule(for: .fajr) == LockRule())
    }

    @Test("The log round-trips and drops junk")
    func logRoundTrips() throws {
        var log = PrayerLog(since: Date(timeIntervalSince1970: 123.5))
        log.record(day: "2026-06-15", kind: .asr, status: .prayed, at: Date(timeIntervalSince1970: 456))

        var object = try jsonObject(JSONEncoder().encode(log))
        #expect(object["version"] as? Int == 1)
        #expect(object["since"] as? Double == 123.5, "times are plain Unix seconds, as Linux writes them")
        var days = try #require(object["days"] as? [String: Any])
        var day = try #require(days["2026-06-15"] as? [String: Any])
        day["sunrise"] = ["status": "prayed", "at": 1] as [String: Any]
        day["isha"] = ["status": "maybe", "at": 1] as [String: Any]
        days["2026-06-15"] = day
        object["days"] = days

        let data = try JSONSerialization.data(withJSONObject: object)
        let back = try JSONDecoder().decode(PrayerLog.self, from: data)
        #expect(back.since.timeIntervalSince1970 == 123.5)
        let kinds = back.days["2026-06-15"].map { Array($0.keys) } ?? []
        #expect(kinds == [PrayerKind.asr])
        #expect(back.entry(day: "2026-06-15", kind: .asr)?.at.timeIntervalSince1970 == 456)
    }

    @Test("The store starts tracking when the file is created")
    func storeStartsTracking() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("prayer-log.json")

        let first = PrayerLogStore(url: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        first.record(day: "2026-06-15", kind: .fajr, status: .prayed, at: Date(timeIntervalSince1970: 10))

        let second = PrayerLogStore(url: url)
        #expect(abs(second.log.since.timeIntervalSince(first.log.since)) < 0.001)
        #expect(second.log.entry(day: "2026-06-15", kind: .fajr)?.status == .prayed)

        first.clear(day: "2026-06-15", kind: .fajr)
        #expect(PrayerLogStore(url: url).log.days.isEmpty)
    }

    @Test("A corrupt log is kept aside")
    func corruptLogKeptAside() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("prayer-log.json")
        try Data("{not json".utf8).write(to: url)

        let store = PrayerLogStore(url: url)
        #expect(store.log.days.isEmpty)
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("prayer-log.corrupt.json").path))
    }
}
