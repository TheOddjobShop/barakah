import Testing
import Foundation
import Adhan
@testable import Barakah

/// A fixed reference: Makkah, using Umm al-Qura, on a known date. Pinning the
/// place and method means these assertions describe Barakah's own layer rather
/// than re-testing the astronomy library underneath it.
private func makkahSettings() -> SettingsData {
    var settings = SettingsData()
    settings.locationMode = .manual
    settings.manualPlace = .makkah
    settings.calculationMethod = .ummAlQura
    settings.madhab = .shafi
    return settings
}

private func makkahCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Riyadh")!
    return calendar
}

private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
    makkahCalendar().date(from: DateComponents(
        year: year, month: month, day: day, hour: hour, minute: minute))!
}

@Suite("Prayer time engine")
struct PrayerTimeEngineTests {

    @Test("A day yields all six markers in chronological order")
    func dayIsOrdered() throws {
        let schedule = try #require(PrayerTimeEngine().schedule(
            for: date(2026, 3, 15), settings: makkahSettings()))

        #expect(schedule.prayers.count == 6)
        #expect(schedule.prayers.map(\.kind) == [.fajr, .sunrise, .dhuhr, .asr, .maghrib, .isha])

        let times = schedule.prayers.map(\.athan)
        #expect(zip(times, times.dropFirst()).allSatisfy { $0 < $1 },
                "each prayer must come strictly after the one before it")
    }

    @Test("Dhuhr falls near solar noon")
    func dhuhrNearSolarNoon() throws {
        let schedule = try #require(PrayerTimeEngine().schedule(
            for: date(2026, 6, 21), settings: makkahSettings()))
        let dhuhr = try #require(schedule.prayer(.dhuhr)).athan
        let hour = makkahCalendar().component(.hour, from: dhuhr)
        // Makkah sits east of its timezone meridian, so solar noon lands just
        // after 12:00 local. Anything outside 11:00–13:00 means a timezone bug.
        #expect((11...13).contains(hour), "Dhuhr at hour \(hour) is not near solar noon")
    }

    @Test("Sunrise carries no iqama, prayers do")
    func sunriseHasNoIqama() throws {
        let schedule = try #require(PrayerTimeEngine().schedule(
            for: date(2026, 3, 15), settings: makkahSettings()))
        #expect(try #require(schedule.prayer(.sunrise)).iqama == nil)
        for kind in PrayerKind.prayers {
            #expect(try #require(schedule.prayer(kind)).iqama != nil,
                    "\(kind.name) should have an iqama by default")
        }
    }

    @Test("Hiding sunrise removes it from the day")
    func sunriseCanBeHidden() throws {
        var settings = makkahSettings()
        settings.showSunrise = false
        let schedule = try #require(PrayerTimeEngine().schedule(for: date(2026, 3, 15), settings: settings))
        #expect(schedule.prayers.count == 5)
        #expect(schedule.prayer(.sunrise) == nil)
    }

    @Test("A per-prayer adjustment shifts only that prayer")
    func adjustmentShiftsOnePrayer() throws {
        let engine = PrayerTimeEngine()
        let base = try #require(engine.schedule(for: date(2026, 3, 15), settings: makkahSettings()))

        var adjusted = makkahSettings()
        adjusted.prayerConfigs[.asr]?.athanAdjustmentMinutes = 7
        let shifted = try #require(engine.schedule(for: date(2026, 3, 15), settings: adjusted))

        let delta = try #require(shifted.prayer(.asr)).athan
            .timeIntervalSince(try #require(base.prayer(.asr)).athan)
        #expect(abs(delta - 7 * 60) < 1)

        let fajrDelta = try #require(shifted.prayer(.fajr)).athan
            .timeIntervalSince(try #require(base.prayer(.fajr)).athan)
        #expect(abs(fajrDelta) < 1, "adjusting Asr must not move Fajr")
    }

    @Test("The Hanafi madhab pushes Asr later than the Shafi'i one")
    func hanafiAsrIsLater() throws {
        let engine = PrayerTimeEngine()
        var hanafi = makkahSettings()
        hanafi.madhab = .hanafi

        let shafiAsr = try #require(engine.schedule(for: date(2026, 3, 15), settings: makkahSettings())?.prayer(.asr)).athan
        let hanafiAsr = try #require(engine.schedule(for: date(2026, 3, 15), settings: hanafi)?.prayer(.asr)).athan
        #expect(hanafiAsr > shafiAsr)
    }
}

@Suite("Iqama rules")
struct IqamaRuleTests {

    @Test("An offset adds exactly its minutes to the athan")
    func offsetAdds() throws {
        let athan = date(2026, 3, 15, 5, 12)
        let iqama = try #require(IqamaRule.offset(minutes: 10).resolve(athan: athan, calendar: makkahCalendar()))
        #expect(iqama.timeIntervalSince(athan) == 600)
    }

    @Test("A fixed time lands on the athan's own day")
    func fixedUsesSameDay() throws {
        let athan = date(2026, 3, 15, 12, 20)
        let iqama = try #require(IqamaRule.fixed(hour: 13, minute: 30)
            .resolve(athan: athan, calendar: makkahCalendar()))
        let parts = makkahCalendar().dateComponents([.year, .month, .day, .hour, .minute], from: iqama)
        #expect(parts.day == 15 && parts.hour == 13 && parts.minute == 30)
    }

    @Test("A fixed time earlier than the athan rolls to the next day")
    func fixedRollsForward() throws {
        // Isha at 23:50 with a fixed iqama of 00:15 belongs to tomorrow, not to
        // twenty-three and a half hours ago.
        let athan = date(2026, 3, 15, 23, 50)
        let iqama = try #require(IqamaRule.fixed(hour: 0, minute: 15)
            .resolve(athan: athan, calendar: makkahCalendar()))
        #expect(iqama > athan)
        #expect(iqama.timeIntervalSince(athan) == 25 * 60)
    }

    @Test("Off yields no iqama")
    func noneIsNil() {
        #expect(IqamaRule.none.resolve(athan: date(2026, 3, 15), calendar: makkahCalendar()) == nil)
        #expect(IqamaRule.none.isEnabled == false)
        #expect(IqamaRule.offset(minutes: 10).isEnabled)
    }
}

@Suite("Event generation")
struct EventTests {

    @Test("Each prayer produces an athan, a reminder and an iqama alert")
    func fullEventSet() throws {
        var settings = makkahSettings()
        for kind in PrayerKind.prayers {
            settings.prayerConfigs[kind]?.iqamaRule = .offset(minutes: 20)
            settings.prayerConfigs[kind]?.iqamaReminderMinutes = 5
            settings.prayerConfigs[kind]?.iqamaAlertEnabled = true
        }

        let start = date(2026, 3, 15, 0, 0)
        let events = PrayerTimeEngine().events(after: start, horizon: 86_400, settings: settings)

        for kind in PrayerKind.prayers {
            let forPrayer = events.filter { $0.prayer == kind }
            #expect(forPrayer.contains { $0.kind == .athan }, "\(kind.name) is missing its athan")
            #expect(forPrayer.contains { $0.kind == .iqama }, "\(kind.name) is missing its iqama")
            #expect(forPrayer.contains {
                if case .iqamaReminder(let m) = $0.kind { return m == 5 }
                return false
            }, "\(kind.name) is missing its reminder")
        }
        #expect(!events.contains { $0.prayer == .sunrise }, "sunrise must never generate events")
    }

    @Test("The reminder lands the configured distance before the iqama")
    func reminderPrecedesIqama() throws {
        var settings = makkahSettings()
        settings.prayerConfigs[.maghrib]?.iqamaRule = .offset(minutes: 15)
        settings.prayerConfigs[.maghrib]?.iqamaReminderMinutes = 10

        let start = date(2026, 3, 15, 0, 0)
        let events = PrayerTimeEngine().events(after: start, horizon: 86_400, settings: settings)

        let athan = try #require(events.first { $0.prayer == .maghrib && $0.kind == .athan })
        let reminder = try #require(events.first {
            $0.prayer == .maghrib && { if case .iqamaReminder = $0.kind { return true }; return false }($0)
        })

        // Athan + 15 min iqama, reminded 10 min earlier, is athan + 5 min.
        #expect(abs(reminder.fireAt.timeIntervalSince(athan.fireAt) - 5 * 60) < 1)
        #expect(reminder.fireAt > athan.fireAt, "a reminder before its own athan is useless")
    }

    @Test("A reminder that would precede the athan is dropped")
    func impossibleReminderIsDropped() throws {
        var settings = makkahSettings()
        // Iqama five minutes after the athan, but reminding thirty minutes
        // before it — that moment is inside the previous prayer's window.
        settings.prayerConfigs[.asr]?.iqamaRule = .offset(minutes: 5)
        settings.prayerConfigs[.asr]?.iqamaReminderMinutes = 30

        let events = PrayerTimeEngine().events(
            after: date(2026, 3, 15, 0, 0), horizon: 86_400, settings: settings)
        let reminders = events.filter {
            $0.prayer == .asr && { if case .iqamaReminder = $0.kind { return true }; return false }($0)
        }
        #expect(reminders.isEmpty)
    }

    @Test("Events are ordered and confined to the horizon")
    func horizonIsRespected() throws {
        let start = date(2026, 3, 15, 0, 0)
        let horizon: TimeInterval = 2 * 86_400
        let events = PrayerTimeEngine().events(after: start, horizon: horizon, settings: makkahSettings())

        #expect(!events.isEmpty)
        #expect(events.allSatisfy { $0.fireAt > start && $0.fireAt <= start.addingTimeInterval(horizon) })
        #expect(zip(events, events.dropFirst()).allSatisfy { $0.fireAt <= $1.fireAt })
    }

    @Test("The Jumu'ah override applies on Friday and no other day")
    func jumuahOnlyOnFriday() throws {
        var settings = makkahSettings()
        settings.jumuahEnabled = true
        settings.jumuahIqamaRule = .fixed(hour: 13, minute: 15)
        settings.prayerConfigs[.dhuhr]?.iqamaRule = .offset(minutes: 20)

        let engine = PrayerTimeEngine()
        let calendar = makkahCalendar()

        // 2026-03-20 is a Friday; 2026-03-19 is not.
        let friday = date(2026, 3, 20)
        #expect(calendar.component(.weekday, from: friday) == 6, "test fixture must actually be a Friday")

        let fridayIqama = try #require(engine.schedule(for: friday, settings: settings)?.prayer(.dhuhr)?.iqama)
        let parts = calendar.dateComponents([.hour, .minute], from: fridayIqama)
        #expect(parts.hour == 13 && parts.minute == 15)

        let thursday = date(2026, 3, 19)
        let thursdayPrayer = try #require(engine.schedule(for: thursday, settings: settings)?.prayer(.dhuhr))
        let offset = try #require(thursdayPrayer.iqama).timeIntervalSince(thursdayPrayer.athan)
        #expect(offset == 20 * 60, "Thursday must keep the ordinary Dhuhr offset")
    }
}

@Suite("Formatting")
struct FormatterTests {
    private let formatter = PrayerFormatter(use24Hour: true, timeZone: TimeZone(identifier: "Asia/Riyadh")!)

    @Test("Countdowns show the two most significant units")
    func countdownUnits() {
        #expect(formatter.countdown(3600 * 2 + 60 * 13) == "2h 13m")
        #expect(formatter.countdown(60 * 42) == "42m")
        #expect(formatter.countdown(31) == "31s")
        #expect(formatter.countdown(-500) == "0s", "a past time must not render as negative")
    }

    @Test("Long countdowns read as sentences")
    func longCountdownReads() {
        #expect(formatter.longCountdown(60) == "in 1 minute")
        #expect(formatter.longCountdown(120) == "in 2 minutes")
        #expect(formatter.longCountdown(3600) == "in 1 hour")
        #expect(formatter.longCountdown(3600 + 300) == "in 1h 5m")
        #expect(formatter.longCountdown(10) == "in less than a minute")
    }
}

@Suite("Settings")
struct SettingsTests {

    @Test("Settings survive a round trip through JSON")
    func codableRoundTrip() throws {
        var settings = SettingsData()
        settings.calculationMethod = .karachi
        settings.madhab = .hanafi
        settings.highLatitudeRule = .seventhOfTheNight
        settings.manualPlace = PlaceSetting(name: "Cairo", latitude: 30.04, longitude: 31.23,
                                            timeZoneIdentifier: "Africa/Cairo")
        settings.prayerConfigs[.isha]?.iqamaRule = .fixed(hour: 21, minute: 0)
        settings.prayerConfigs[.fajr]?.iqamaReminderMinutes = 12
        settings.athanSound = .bundled("adhan")
        settings.resumeMode = .afterMinutes(7)

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(SettingsData.self, from: encoded)
        #expect(decoded == settings)
    }

    @Test("Every prayer has a default configuration")
    func defaultsAreComplete() {
        let settings = SettingsData()
        for kind in PrayerKind.allCases {
            let config = settings.config(for: kind)
            if kind.isPrayer {
                #expect(config.athanEnabled)
                #expect(config.iqamaRule == .offset(minutes: 10),
                        "the default should be the 'athan + 10' the request actually asked for")
            } else {
                #expect(!config.athanEnabled, "sunrise must never sound an athan")
            }
        }
    }

    @Test("The active place follows the location mode")
    func activePlaceFollowsMode() {
        var settings = SettingsData()
        let detected = PlaceSetting(name: "Detected", latitude: 1, longitude: 2)
        settings.resolvedPlace = detected

        settings.locationMode = .automatic
        #expect(settings.activePlace == detected)

        settings.locationMode = .manual
        #expect(settings.activePlace == settings.manualPlace)

        // Falling back to the manual place keeps times available before the
        // first fix arrives, rather than showing nothing.
        settings.locationMode = .automatic
        settings.resolvedPlace = nil
        #expect(settings.activePlace == settings.manualPlace)
    }

    @Test("A custom angle overrides the method and clears the Isha interval")
    func customAnglesApply() {
        var settings = SettingsData()
        settings.calculationMethod = .ummAlQura   // uses a 90-minute Isha interval
        settings.customFajrAngle = 16.5
        settings.customIshaAngle = 15.0

        let params = settings.calculationParameters
        #expect(params.fajrAngle == 16.5)
        #expect(params.ishaAngle == 15.0)
        #expect(params.ishaInterval == 0, "an explicit angle must replace the interval")
    }
}
