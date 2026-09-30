import Testing
import Foundation
import Adhan
@testable import Barakah

/// Pins the Linux build's calculation to this one.
///
/// The Linux tray app (`linux/`) carries a Python port of adhan-swift and of
/// `PrayerTimeEngine`. This suite computes a grid of places, methods, madhhabs,
/// high-latitude rules and dates — plus a handful of fully configured settings
/// files with iqama rules, Jumu'ah and adjustments — and compares the result
/// with `linux/tests/parity.json`. The Python tests compare their own output
/// with the same file, so the two builds can only drift apart by failing a test.
///
/// After a deliberate change to the calculation, regenerate the fixture:
///
///     BARAKAH_WRITE_PARITY=1 swift test --filter LinuxParity
@Suite("Linux parity")
struct LinuxParityTests {

    private static let places: [PlaceSetting] = [
        .makkah,
        PlaceSetting(name: "Los Angeles", latitude: 34.0522, longitude: -118.2437, timeZoneIdentifier: "America/Los_Angeles"),
        PlaceSetting(name: "New York", latitude: 40.7128, longitude: -74.0060, timeZoneIdentifier: "America/New_York"),
        PlaceSetting(name: "London", latitude: 51.5074, longitude: -0.1278, timeZoneIdentifier: "Europe/London"),
        PlaceSetting(name: "Oslo", latitude: 59.9139, longitude: 10.7522, timeZoneIdentifier: "Europe/Oslo"),
        PlaceSetting(name: "Reykjavik", latitude: 64.1466, longitude: -21.9426, timeZoneIdentifier: "Atlantic/Reykjavik"),
        PlaceSetting(name: "Tromsø", latitude: 69.6492, longitude: 18.9553, timeZoneIdentifier: "Europe/Oslo"),
        PlaceSetting(name: "Sydney", latitude: -33.8688, longitude: 151.2093, timeZoneIdentifier: "Australia/Sydney"),
        PlaceSetting(name: "Apia", latitude: -13.8333, longitude: -171.7667, timeZoneIdentifier: "Pacific/Apia"),
        PlaceSetting(name: "Jakarta", latitude: -6.2088, longitude: 106.8456, timeZoneIdentifier: "Asia/Jakarta"),
        PlaceSetting(name: "Tehran", latitude: 35.6892, longitude: 51.3890, timeZoneIdentifier: "Asia/Tehran"),
        PlaceSetting(name: "Istanbul", latitude: 41.0082, longitude: 28.9784, timeZoneIdentifier: "Europe/Istanbul"),
        PlaceSetting(name: "Anchorage", latitude: 61.2181, longitude: -149.9003, timeZoneIdentifier: "America/Anchorage"),
    ]

    /// Solstices, equinox-adjacent days, both DST changes on each side of the
    /// Atlantic, and a leap-adjacent February day.
    private static let days: [(Int, Int, Int)] = [
        (2026, 1, 1), (2026, 3, 8), (2026, 3, 29), (2026, 6, 21),
        (2026, 9, 29), (2026, 11, 1), (2026, 12, 21), (2027, 2, 28),
    ]

    private static let rules: [HighLatitudeRule?] = [nil, .middleOfTheNight, .seventhOfTheNight, .twilightAngle]

    private static var fixtureURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // BarakahTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("linux/tests/parity.json")
    }

    private static func instant(_ place: PlaceSetting, _ day: (Int, Int, Int), hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = place.timeZone
        return calendar.date(from: DateComponents(year: day.0, month: day.1, day: day.2, hour: hour))!
    }

    private static func offset(_ date: Date?, from base: Double) -> Any {
        guard let date else { return NSNull() }
        return date.timeIntervalSince1970 - base
    }

    private static func encode(_ schedule: DaySchedule?) -> Any {
        guard let schedule else { return NSNull() }
        let base = schedule.day.timeIntervalSince1970
        return [
            "day": base,
            "prayers": schedule.prayers.map { prayer -> [Any] in
                [prayer.kind.rawValue,
                 prayer.athan.timeIntervalSince1970 - base,
                 offset(prayer.iqama, from: base)]
            },
            "sunnah": [
                offset(schedule.middleOfTheNight, from: base),
                offset(schedule.lastThirdOfTheNight, from: base),
            ],
        ] as [String: Any]
    }

    private static func encode(_ event: PrayerEvent) -> [Any] {
        switch event.kind {
        case .athan:
            [event.prayer.rawValue, "athan", 0, event.fireAt.timeIntervalSince1970]
        case .iqamaReminder(let minutes):
            [event.prayer.rawValue, "iqamaReminder", minutes, event.fireAt.timeIntervalSince1970]
        case .iqama:
            [event.prayer.rawValue, "iqama", 0, event.fireAt.timeIntervalSince1970]
        }
    }

    // MARK: - The grid

    private static func gridEntries() -> [[String: Any]] {
        let engine = PrayerTimeEngine()
        var entries: [[String: Any]] = []
        var index = 0
        for (placeIndex, place) in places.enumerated() {
            for day in days {
                for method in CalculationMethod.selectable {
                    let madhab: Madhab = index % 2 == 0 ? .shafi : .hanafi
                    let rule = rules[(index / 2) % rules.count]
                    index += 1

                    var settings = SettingsData()
                    settings.locationMode = .manual
                    settings.manualPlace = place
                    settings.calculationMethod = method
                    settings.madhab = madhab
                    settings.highLatitudeRule = rule

                    let at = instant(place, day)
                    entries.append([
                        "place": placeIndex,
                        "method": method.rawValue,
                        "madhab": madhab.rawValue,
                        "rule": rule?.rawValue ?? NSNull(),
                        "at": at.timeIntervalSince1970,
                        "schedule": encode(engine.schedule(for: at, settings: settings)),
                    ])
                }
            }
        }
        return entries
    }

    // MARK: - Fully configured settings

    private static func richSettings() -> [(SettingsData, Date)] {
        var cases: [(SettingsData, Date)] = []
        let la = places[1], makkah = places[0], london = places[3], oslo = places[4]
        let tromso = places[6], sydney = places[7], newYork = places[2]

        // Defaults, as a fresh install would have them, pinned to Los Angeles.
        var plain = SettingsData()
        plain.locationMode = .manual
        plain.manualPlace = la
        cases.append((plain, instant(la, (2026, 9, 29), hour: 9)))

        // A masjid timetable: every iqama shape, adjustments, Jumu'ah, a silent
        // prayer with no media action, and an iqama alert.
        var masjid = SettingsData()
        masjid.locationMode = .automatic
        masjid.resolvedPlace = la
        masjid.calculationMethod = .northAmerica
        masjid.jumuahEnabled = true
        masjid.jumuahIqamaRule = .fixed(hour: 13, minute: 15)
        masjid.jumuahReminderMinutes = 20
        masjid.notifyAtAthan = false
        masjid.prayerConfigs[.fajr] = PrayerConfig(iqamaRule: .fixed(hour: 5, minute: 45), iqamaReminderMinutes: 10, athanAdjustmentMinutes: 2)
        masjid.prayerConfigs[.dhuhr] = PrayerConfig(iqamaRule: .fixed(hour: 13, minute: 30), iqamaReminderMinutes: 0)
        masjid.prayerConfigs[.asr] = PrayerConfig(athanEnabled: false, mediaMode: .off, iqamaRule: .offset(minutes: 15), iqamaReminderMinutes: 5)
        masjid.prayerConfigs[.maghrib] = PrayerConfig(mediaMode: .pauseAndMute, iqamaRule: .offset(minutes: 5), iqamaReminderMinutes: 3, iqamaAlertEnabled: true, athanAdjustmentMinutes: -1)
        masjid.prayerConfigs[.isha] = PrayerConfig(iqamaRule: .fixed(hour: 21, minute: 0), iqamaReminderMinutes: 15)
        masjid.prayerConfigs[.sunrise] = PrayerConfig(athanEnabled: false, mediaMode: .off, iqamaRule: .none, iqamaReminderMinutes: 0, athanAdjustmentMinutes: 1)
        masjid.resumeMode = .afterMinutes(7)
        masjid.athanSound = .chime
        masjid.fajrAthanSound = .bundled("Adhan")
        masjid.menuBarStyle = .countdown
        masjid.use24HourClock = true
        // Thursday evening, so the three-day horizon spans a Friday.
        cases.append((masjid, instant(la, (2026, 10, 1), hour: 18)))
        // The same timetable across both US DST changes.
        cases.append((masjid, instant(la, (2026, 3, 7), hour: 22)))
        cases.append((masjid, instant(la, (2026, 10, 31), hour: 22)))

        // Umm al-Qura without sunrise, with a custom file and no resume.
        var umm = SettingsData()
        umm.locationMode = .manual
        umm.manualPlace = makkah
        umm.calculationMethod = .ummAlQura
        umm.showSunrise = false
        umm.athanSound = .silent
        umm.fajrAthanSound = .custom(bookmark: Data("/home/example/Athan/Fajr.ogg".utf8), displayName: "Fajr")
        umm.resumeMode = .afterIqama
        cases.append((umm, instant(makkah, (2026, 6, 21), hour: 3)))

        // Custom angles override the method and clear Isha's fixed interval.
        var custom = SettingsData()
        custom.locationMode = .manual
        custom.manualPlace = london
        custom.calculationMethod = .moonsightingCommittee
        custom.customFajrAngle = 15
        custom.customIshaAngle = 15
        custom.resumeMode = .afterAthan
        cases.append((custom, instant(london, (2026, 3, 28), hour: 12)))

        var qatarCustom = SettingsData()
        qatarCustom.locationMode = .manual
        qatarCustom.manualPlace = makkah
        qatarCustom.calculationMethod = .qatar
        qatarCustom.customIshaAngle = 17
        cases.append((qatarCustom, instant(makkah, (2026, 1, 15), hour: 12)))

        // High latitude, Hanafi, twilight-angle rule.
        var north = SettingsData()
        north.locationMode = .manual
        north.manualPlace = oslo
        north.madhab = .hanafi
        north.highLatitudeRule = .twilightAngle
        cases.append((north, instant(oslo, (2026, 6, 19), hour: 12)))

        // An Isha iqama after midnight: a fixed time that lands "before" the
        // athan belongs to the next day.
        var late = SettingsData()
        late.locationMode = .manual
        late.manualPlace = london
        late.prayerConfigs[.isha] = PrayerConfig(iqamaRule: .fixed(hour: 0, minute: 30), iqamaReminderMinutes: 10, iqamaAlertEnabled: true)
        cases.append((late, instant(london, (2026, 6, 20), hour: 20)))

        // Midnight sun: days with no computable Isha drop out entirely.
        var polar = SettingsData()
        polar.locationMode = .manual
        polar.manualPlace = tromso
        polar.calculationMethod = .muslimWorldLeague
        cases.append((polar, instant(tromso, (2026, 6, 20), hour: 12)))
        var polarRule = polar
        polarRule.highLatitudeRule = .seventhOfTheNight
        cases.append((polarRule, instant(tromso, (2026, 6, 20), hour: 12)))

        // Southern hemisphere, across Sydney's April DST change.
        var south = SettingsData()
        south.locationMode = .manual
        south.manualPlace = sydney
        south.calculationMethod = .muslimWorldLeague
        south.prayerConfigs[.fajr] = PrayerConfig(iqamaRule: .fixed(hour: 5, minute: 30))
        cases.append((south, instant(sydney, (2026, 4, 3), hour: 20)))

        // Singapore rounds up; Tehran computes Maghrib by angle; Dubai and
        // Diyanet carry method offsets.
        for (method, place) in [(CalculationMethod.singapore, places[9]), (.tehran, places[10]),
                                (.dubai, makkah), (.turkey, places[11]), (.moonsightingCommittee, newYork)] {
            var s = SettingsData()
            s.locationMode = .manual
            s.manualPlace = place
            s.calculationMethod = method
            cases.append((s, instant(place, (2026, 9, 29), hour: 6)))
        }
        return cases
    }

    private static func richEntries() throws -> [[String: Any]] {
        let engine = PrayerTimeEngine()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try richSettings().map { settings, at in
            let json = try JSONSerialization.jsonObject(with: encoder.encode(settings))
            return [
                "settings": json,
                "at": at.timeIntervalSince1970,
                "schedule": encode(engine.schedule(for: at, settings: settings)),
                "events": engine.events(after: at, horizon: 3 * 86_400, settings: settings).map(encode),
            ]
        }
    }

    // MARK: - Writing and checking

    private static func serialise(_ object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private static func document() throws -> String {
        let places = places.map { place -> [String: Any] in
            ["name": place.name, "latitude": place.latitude, "longitude": place.longitude,
             "timeZoneIdentifier": place.timeZoneIdentifier]
        }
        // One entry per line so a regenerated fixture diffs readably.
        var lines = ["{", "\"generator\": \"Tests/BarakahTests/LinuxParityTests.swift\","]
        lines.append("\"places\": \(try serialise(places)),")
        lines.append("\"grid\": [")
        let grid = try gridEntries().map(serialise)
        lines.append(grid.joined(separator: ",\n"))
        lines.append("],")
        lines.append("\"rich\": [")
        let rich = try richEntries().map(serialise)
        lines.append(rich.joined(separator: ",\n"))
        lines.append("]")
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    @Test("The Linux fixture matches this engine")
    func fixtureMatches() throws {
        let generated = try Self.document()
        if ProcessInfo.processInfo.environment["BARAKAH_WRITE_PARITY"] != nil {
            try FileManager.default.createDirectory(
                at: Self.fixtureURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try generated.write(to: Self.fixtureURL, atomically: true, encoding: .utf8)
            return
        }
        let stored = try Data(contentsOf: Self.fixtureURL)
        let expected = try JSONSerialization.jsonObject(with: stored) as? NSDictionary
        let actual = try JSONSerialization.jsonObject(with: Data(generated.utf8)) as? NSDictionary
        #expect(expected != nil && expected == actual,
                "linux/tests/parity.json is stale — regenerate with BARAKAH_WRITE_PARITY=1 swift test --filter LinuxParity")
    }
}
