import Foundation
import Adhan

/// Turns settings plus a date into concrete prayer times. Pure and synchronous —
/// no state, no I/O — which makes the whole time model straightforward to test.
public struct PrayerTimeEngine: Sendable {
    public init() {}

    /// Compute one day's schedule for the place in `settings`.
    ///
    /// `date` is interpreted in the place's own timezone, so a schedule requested
    /// while travelling still describes the right calendar day at that location.
    public func schedule(for date: Date, settings: SettingsData) -> DaySchedule? {
        let place = settings.activePlace
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = place.timeZone

        let dayComponents = calendar.dateComponents([.year, .month, .day], from: date)
        let coordinates = Coordinates(latitude: place.latitude, longitude: place.longitude)

        guard let times = PrayerTimes(
            coordinates: coordinates,
            date: dayComponents,
            calculationParameters: settings.calculationParameters
        ), let dayStart = calendar.date(from: dayComponents) else {
            return nil
        }

        let isFriday = calendar.component(.weekday, from: dayStart) == 6

        var scheduled: [ScheduledPrayer] = []
        for kind in PrayerKind.displayOrder {
            if kind == .sunrise && !settings.showSunrise { continue }
            let base = times.time(for: kind.adhanPrayer)
            let adjustment = settings.config(for: kind).athanAdjustmentMinutes
            let athan = calendar.date(byAdding: .minute, value: adjustment, to: base) ?? base

            let iqama: Date? = kind.isPrayer
                ? settings
                    .effectiveIqamaRule(for: kind, isFriday: isFriday)
                    .resolve(athan: athan, calendar: calendar)
                : nil

            scheduled.append(ScheduledPrayer(kind: kind, athan: athan, iqama: iqama))
        }
        scheduled.sort { $0.athan < $1.athan }

        let sunnah = SunnahTimes(from: times)

        return DaySchedule(
            day: dayStart,
            place: place,
            prayers: scheduled,
            middleOfTheNight: sunnah?.middleOfTheNight,
            lastThirdOfTheNight: sunnah?.lastThirdOfTheNight
        )
    }

    /// Schedules for `count` consecutive days beginning at `date`.
    public func schedules(from date: Date, count: Int, settings: SettingsData) -> [DaySchedule] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = settings.activePlace.timeZone
        return (0..<max(0, count)).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { return nil }
            return schedule(for: day, settings: settings)
        }
    }

    /// Every event that should fire in the window `(after, after + horizon]`.
    ///
    /// Built by walking whole days and filtering, which naturally handles prayers
    /// whose iqama spills past midnight and days where a prayer is missing at
    /// extreme latitudes.
    public func events(
        after start: Date,
        horizon: TimeInterval,
        settings: SettingsData
    ) -> [PrayerEvent] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = settings.activePlace.timeZone
        let end = start.addingTimeInterval(horizon)

        // Start a day early: a late Isha iqama or reminder can belong to yesterday.
        let firstDay = calendar.date(byAdding: .day, value: -1, to: start) ?? start
        let dayCount = Int(ceil(horizon / 86_400)) + 2

        var events: [PrayerEvent] = []
        for day in schedules(from: firstDay, count: dayCount, settings: settings) {
            let isFriday = calendar.component(.weekday, from: day.day) == 6
            for prayer in day.prayers where prayer.kind.isPrayer {
                let config = settings.config(for: prayer.kind)

                if config.athanEnabled || settings.notifyAtAthan || config.mediaMode.pausesPlayers {
                    events.append(PrayerEvent(prayer: prayer.kind, kind: .athan, fireAt: prayer.athan))
                }

                guard let iqama = prayer.iqama else { continue }

                let reminderMinutes = settings.effectiveReminderMinutes(for: prayer.kind, isFriday: isFriday)
                if reminderMinutes > 0,
                   let reminderAt = calendar.date(byAdding: .minute, value: -reminderMinutes, to: iqama),
                   reminderAt > prayer.athan {
                    events.append(PrayerEvent(
                        prayer: prayer.kind,
                        kind: .iqamaReminder(minutesBefore: reminderMinutes),
                        fireAt: reminderAt
                    ))
                }

                if config.iqamaAlertEnabled {
                    events.append(PrayerEvent(prayer: prayer.kind, kind: .iqama, fireAt: iqama))
                }
            }
        }

        return events
            .filter { $0.fireAt > start && $0.fireAt <= end }
            .sorted { $0.fireAt < $1.fireAt }
    }
}
