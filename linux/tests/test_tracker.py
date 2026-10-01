"""The prayer log, prayer windows, and when the prayer lock is due."""

import json
import os
import tempfile
import unittest

from barakah.engine import PrayerTimeEngine, make_instant, place_zone
from barakah.model import LockRule, PlaceSetting, PrayerLockSettings, SettingsData
from barakah.store import PrayerLogStore
from barakah.tracker import (
    EXCUSED, MISSED, OPEN, PRAYED, QADA, UNTRACKED, UPCOMING, DayRecord, PrayerLog, heat, history,
    lock_state, longest_streak, on_time_ratio, status, status_for_record, streak, window_at, windows,
)

LA = PlaceSetting("Los Angeles", 34.0522, -118.2437, "America/Los_Angeles")
TZ = place_zone(LA)


def settings(lock: bool = True, show_sunrise: bool = True, **rules) -> SettingsData:
    s = SettingsData()
    s.location_mode = "manual"
    s.manual_place = LA
    s.show_sunrise = show_sunrise
    if lock:
        s.prayer_lock = PrayerLockSettings(True)
        for kind, rule in rules.items():
            s.prayer_lock.rules[kind] = rule
    return s


def at(hour: int, minute: int = 0, day: int = 15) -> float:
    return make_instant(TZ, 2026, 6, day, hour, minute)


class WindowTests(unittest.TestCase):
    def setUp(self):
        self.engine = PrayerTimeEngine()

    def test_five_windows_chain_into_each_other(self):
        found = windows(at(12), settings(), self.engine)
        self.assertEqual([w.kind for w in found], ["fajr", "dhuhr", "asr", "maghrib", "isha"])
        self.assertTrue(all(w.day == "2026-06-15" for w in found))
        for earlier, later in zip(found[1:], found[2:]):
            self.assertEqual(earlier.end, later.start)

    def test_fajr_ends_at_sunrise_even_when_sunrise_is_hidden(self):
        shown = windows(at(12), settings(show_sunrise=True), self.engine)[0]
        hidden = windows(at(12), settings(show_sunrise=False), self.engine)[0]
        self.assertEqual(shown, hidden)
        self.assertLess(hidden.end, windows(at(12), settings(), self.engine)[1].start)

    def test_isha_runs_to_the_next_fajr(self):
        isha = windows(at(12), settings(), self.engine)[-1]
        next_fajr = windows(at(12, day=16), settings(), self.engine)[0]
        self.assertEqual(isha.end, next_fajr.start)

    def test_before_fajr_is_yesterdays_isha(self):
        window = window_at(at(2, day=16), settings(), self.engine)
        self.assertEqual((window.kind, window.day), ("isha", "2026-06-15"))

    def test_between_sunrise_and_dhuhr_is_no_ones_time(self):
        self.assertIsNone(window_at(at(9), settings(), self.engine))


class StatusTests(unittest.TestCase):
    def setUp(self):
        self.dhuhr = windows(at(12), settings())[1]

    def test_derived_statuses(self):
        log = PrayerLog(since=at(0))
        self.assertEqual(status(log, self.dhuhr, self.dhuhr.start - 60), UPCOMING)
        self.assertEqual(status(log, self.dhuhr, self.dhuhr.start + 60), OPEN)
        self.assertEqual(status(log, self.dhuhr, self.dhuhr.end + 60), MISSED)

    def test_prayers_before_tracking_began_are_untracked(self):
        log = PrayerLog(since=self.dhuhr.start + 1)
        self.assertEqual(status(log, self.dhuhr, self.dhuhr.end + 60), UNTRACKED)

    def test_recorded_status_wins(self):
        log = PrayerLog(since=at(0))
        log.record(self.dhuhr.day, "dhuhr", QADA, self.dhuhr.end + 60)
        self.assertEqual(status(log, self.dhuhr, self.dhuhr.end + 120), QADA)

    def test_an_oath_after_the_window_is_qada(self):
        self.assertEqual(status_for_record(self.dhuhr, self.dhuhr.end - 1), PRAYED)
        self.assertEqual(status_for_record(self.dhuhr, self.dhuhr.end), QADA)


class LockTests(unittest.TestCase):
    def setUp(self):
        self.engine = PrayerTimeEngine()
        self.log = PrayerLog(since=at(0))
        self.dhuhr = windows(at(12), settings(), self.engine)[1]

    def state(self, now, s=None):
        return lock_state(now, s or settings(), self.log, self.engine)

    def test_off_by_default(self):
        self.assertIsNone(SettingsData().prayer_lock)
        self.assertFalse(SettingsData().lock.enabled)
        self.assertIsNone(self.state(self.dhuhr.start + 3600, settings(lock=False)).active)

    def test_locks_after_the_grace_period(self):
        grace = 15 * 60
        before = self.state(self.dhuhr.start + grace - 1)
        self.assertIsNone(before.active)
        self.assertEqual(before.next_at, self.dhuhr.start + grace)
        self.assertEqual(self.state(self.dhuhr.start + grace).active, self.dhuhr)

    def test_an_oath_releases_it(self):
        self.log.record(self.dhuhr.day, "dhuhr", PRAYED, self.dhuhr.start + 600)
        self.assertIsNone(self.state(self.dhuhr.start + 3600).active)

    def test_praying_before_the_grace_period_ends_prevents_it(self):
        self.log.record(self.dhuhr.day, "dhuhr", PRAYED, self.dhuhr.start + 60)
        state = self.state(self.dhuhr.start + 120)
        self.assertIsNone(state.active)
        self.assertEqual(state.next_window.kind, "asr")

    def test_it_ends_with_the_window(self):
        self.assertEqual(self.state(self.dhuhr.end - 1).active, self.dhuhr)
        self.assertIsNone(self.state(self.dhuhr.end + 1).active)

    def test_a_disabled_prayer_never_locks(self):
        s = settings(dhuhr=LockRule(enabled=False))
        self.assertIsNone(self.state(self.dhuhr.start + 3600, s).active)

    def test_a_grace_longer_than_the_window_never_locks(self):
        s = settings(dhuhr=LockRule(grace_minutes=24 * 60))
        self.assertIsNone(self.state(self.dhuhr.start + 3600, s).active)

    def test_isha_still_locks_after_midnight(self):
        state = self.state(at(1, day=16))
        self.assertEqual((state.active.kind, state.active.day), ("isha", "2026-06-15"))

    def test_nothing_before_tracking_began_locks(self):
        self.log.since = self.dhuhr.start + 1
        self.assertIsNone(self.state(self.dhuhr.start + 3600).active)


class HistoryTests(unittest.TestCase):
    def test_streak_counts_complete_days_and_spares_today(self):
        full = {k: PRAYED for k in ("fajr", "dhuhr", "asr", "maghrib", "isha")}
        today = dict(full, maghrib=OPEN, isha=UPCOMING)
        records = [DayRecord("d0", today), DayRecord("d1", full), DayRecord("d2", dict(full, asr=EXCUSED)),
                   DayRecord("d3", dict(full, fajr=MISSED)), DayRecord("d4", full)]
        self.assertEqual(streak(records), 2)
        self.assertEqual(streak([DayRecord("d0", full)] + records[1:]), 3)
        self.assertEqual(streak([DayRecord("d0", dict(today, fajr=MISSED))] + records[1:]), 0)

    def test_ratio_ignores_what_is_not_yet_owed(self):
        records = [DayRecord("d0", {"fajr": PRAYED, "dhuhr": QADA, "asr": MISSED, "maghrib": OPEN,
                                    "isha": UNTRACKED})]
        self.assertAlmostEqual(on_time_ratio(records), 1 / 3)
        self.assertIsNone(on_time_ratio([DayRecord("d0", {"fajr": UPCOMING})]))

    def test_history_is_newest_first(self):
        log = PrayerLog(since=at(0, day=14))
        log.record("2026-06-14", "fajr", PRAYED, at(5, day=14))
        records = history(log, settings(), at(12), 3)
        self.assertEqual([r.day for r in records], ["2026-06-15", "2026-06-14", "2026-06-13"])
        self.assertEqual(records[1].statuses["fajr"], PRAYED)
        self.assertEqual(records[1].statuses["dhuhr"], MISSED)
        self.assertEqual(records[2].statuses["fajr"], UNTRACKED)
        self.assertEqual(records[0].statuses["isha"], UPCOMING)


class YearTests(unittest.TestCase):
    def test_settled_days_agree_with_computing_every_window(self):
        engine = PrayerTimeEngine()
        s = settings()
        now = at(12, day=20)
        log = PrayerLog(since=at(15, day=10))  # tracking began mid-afternoon
        log.record("2026-06-12", "asr", PRAYED, 0)
        log.record("2026-06-09", "fajr", QADA, 0)
        log.record("2026-06-19", "isha", EXCUSED, 0)
        fast = history(log, s, now, 14, engine)
        for record in fast:
            day = make_instant(TZ, *(int(x) for x in record.day.split("-")), 12)
            slow = {w.kind: status(log, w, now) for w in windows(day, s, engine)}
            self.assertEqual(record.statuses, slow, record.day)
        self.assertEqual(fast[10].statuses["dhuhr"], UNTRACKED)  # June 10, before tracking began
        self.assertEqual(fast[10].statuses["maghrib"], MISSED)   # June 10, after it began

    def test_a_year_is_cheap(self):
        import time as clock
        log = PrayerLog(since=at(0, day=1) - 400 * 86400)
        started = clock.perf_counter()
        records = history(log, settings(), at(12), 371)
        self.assertEqual(len(records), 371)
        self.assertLess(clock.perf_counter() - started, 0.5)

    def test_heat_counts_kept_prayers(self):
        def day(**statuses):
            base = {k: MISSED for k in ("fajr", "dhuhr", "asr", "maghrib", "isha")}
            base.update(statuses)
            return DayRecord("d", base)
        self.assertIsNone(heat(DayRecord("d", {k: UNTRACKED for k in ("fajr", "dhuhr")})))
        self.assertEqual(heat(day()).level, 0)
        self.assertEqual(heat(day(fajr=PRAYED, dhuhr=QADA)).level, 1)                  # 1.5
        self.assertEqual(heat(day(fajr=PRAYED, dhuhr=PRAYED, asr=EXCUSED)).level, 2)   # 3
        self.assertEqual(heat(day(fajr=PRAYED, dhuhr=PRAYED, asr=PRAYED, maghrib=PRAYED, isha=QADA)).level, 3)
        full = heat(day(fajr=PRAYED, dhuhr=PRAYED, asr=PRAYED, maghrib=EXCUSED, isha=PRAYED))
        self.assertEqual((full.level, full.on_time, full.excused, full.missed), (4, 4, 1, 0))

    def test_longest_streak(self):
        full = {k: PRAYED for k in ("fajr", "dhuhr", "asr", "maghrib", "isha")}
        broken = dict(full, asr=MISSED)
        records = [DayRecord(str(i), r) for i, r in enumerate([broken, full, full, broken, full, full, full, broken])]
        self.assertEqual(longest_streak(records), 3)


class PersistenceTests(unittest.TestCase):
    def test_settings_round_trip_and_stay_absent_until_set(self):
        self.assertNotIn("prayerLock", SettingsData().to_json())
        s = settings(dhuhr=LockRule(True, 40))
        back = SettingsData.from_json(json.loads(json.dumps(s.to_json())))
        self.assertTrue(back.lock.enabled)
        self.assertEqual(back.lock.rule("dhuhr"), LockRule(True, 40))
        self.assertEqual(back.lock.rule("isha"), LockRule())

    def test_log_round_trips_and_drops_junk(self):
        log = PrayerLog(since=123.5)
        log.record("2026-06-15", "asr", PRAYED, 456.0)
        data = log.to_json()
        data["days"]["2026-06-15"]["sunrise"] = {"status": PRAYED, "at": 1}
        data["days"]["2026-06-15"]["isha"] = {"status": "maybe", "at": 1}
        back = PrayerLog.from_json(json.loads(json.dumps(data)))
        self.assertEqual(back.since, 123.5)
        self.assertEqual(list(back.days["2026-06-15"]), ["asr"])
        self.assertEqual(back.entry("2026-06-15", "asr").at, 456.0)

    def test_store_starts_tracking_when_the_file_is_created(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "prayer-log.json")
            first = PrayerLogStore(path)
            self.assertTrue(os.path.exists(path))
            first.record("2026-06-15", "fajr", PRAYED, 10.0)
            second = PrayerLogStore(path)
            self.assertEqual(second.log.since, first.log.since)
            self.assertEqual(second.log.entry("2026-06-15", "fajr").status, PRAYED)
            first.clear("2026-06-15", "fajr")
            self.assertEqual(PrayerLogStore(path).log.days, {})

    def test_a_corrupt_log_is_kept_aside(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "prayer-log.json")
            with open(path, "w") as fh:
                fh.write("{not json")
            store = PrayerLogStore(path)
            self.assertEqual(store.log.days, {})
            self.assertTrue(os.path.exists(os.path.join(tmp, "prayer-log.corrupt.json")))


if __name__ == "__main__":
    unittest.main()
