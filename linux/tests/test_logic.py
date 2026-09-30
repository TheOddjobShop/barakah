"""The Linux-only pieces around the engine: settings defaults and JSON shape,
formatting, notification text, and the scheduler-facing event keys."""

import json
import os
import unittest
from zoneinfo import ZoneInfo

from barakah.engine import PrayerEvent, make_instant, resolve_iqama
from barakah.formatting import PrayerFormatter
from barakah.model import AthanSound, IqamaRule, MediaResumeMode, PlaceSetting, SettingsData
from barakah.notify import content, notify_send_args

FIXTURE = os.path.join(os.path.dirname(__file__), "parity.json")
LA = PlaceSetting("Los Angeles", 34.0522, -118.2437, "America/Los_Angeles")


class SettingsTests(unittest.TestCase):
    def test_defaults_match_the_swift_app(self):
        # The first configured case in the fixture is a fresh SettingsData()
        # pinned to Los Angeles; everything else must be the Swift defaults.
        with open(FIXTURE, encoding="utf-8") as fh:
            swift = json.load(fh)["rich"][0]["settings"]
        ours = SettingsData()
        ours.location_mode = "manual"
        ours.manual_place = PlaceSetting.from_json(swift["manualPlace"])
        self.assertEqual(ours.to_json(), swift)

    def test_unknown_keys_survive(self):
        data = SettingsData().to_json()
        data["someFutureSetting"] = {"x": 1}
        self.assertEqual(SettingsData.from_json(data).to_json()["someFutureSetting"], {"x": 1})

    def test_missing_keys_take_defaults(self):
        s = SettingsData.from_json({"calculationMethod": "karachi"})
        self.assertEqual(s.calculation_method, "karachi")
        self.assertEqual(s.config("isha").iqama_rule, IqamaRule.offset(10))
        self.assertEqual(s.resume_mode, MediaResumeMode("never"))

    def test_custom_sound_is_a_path_on_linux(self):
        sound = AthanSound.custom_path("/home/me/Athan/Makkah Fajr.ogg")
        self.assertEqual(sound.label, "Makkah Fajr")
        self.assertEqual(AthanSound.from_json(sound.to_json()).custom_file, "/home/me/Athan/Makkah Fajr.ogg")
        # A Mac bookmark is not a path and must not be mistaken for one.
        mac = AthanSound.from_json({"custom": {"bookmark": "Ym9va4ADAAAAAAQQMAAA", "displayName": "X"}})
        self.assertIsNone(mac.custom_file)


class FormattingTests(unittest.TestCase):
    def test_times_render_in_the_place_zone(self):
        ts = make_instant(ZoneInfo("America/Los_Angeles"), 2026, 9, 29, 18, 54)
        self.assertEqual(PrayerFormatter(False, LA).time(ts), "6:54 PM")
        self.assertEqual(PrayerFormatter(True, LA).time(ts), "18:54")
        riyadh = PlaceSetting("Makkah", 21.4, 39.8, "Asia/Riyadh")
        self.assertEqual(PrayerFormatter(True, riyadh).time(ts), "04:54")

    def test_countdowns(self):
        self.assertEqual(PrayerFormatter.countdown(4320), "1h 12m")
        self.assertEqual(PrayerFormatter.countdown(720), "12m")
        self.assertEqual(PrayerFormatter.countdown(48), "48s")
        self.assertEqual(PrayerFormatter.long_countdown(30), "in less than a minute")
        self.assertEqual(PrayerFormatter.long_countdown(60), "in 1 minute")
        self.assertEqual(PrayerFormatter.long_countdown(7200), "in 2 hours")
        self.assertEqual(PrayerFormatter.long_countdown(4320), "in 1h 12m")


class NotificationTests(unittest.TestCase):
    def setUp(self):
        self.settings = SettingsData()
        self.settings.location_mode = "manual"
        self.settings.manual_place = LA
        self.fmt = PrayerFormatter(False, LA)
        self.maghrib = make_instant(ZoneInfo("America/Los_Angeles"), 2026, 9, 29, 18, 54)

    def test_athan_text(self):
        title, body = content(PrayerEvent("maghrib", "athan", self.maghrib), self.settings, self.fmt)
        self.assertEqual(title, "Maghrib — 6:54 PM")
        self.assertEqual(body, "It is time for Maghrib.")

    def test_reminder_text_names_the_iqama_time(self):
        event = PrayerEvent("maghrib", "iqamaReminder", self.maghrib + 5 * 60, minutes_before=5)
        title, body = content(event, self.settings, self.fmt)
        self.assertEqual(title, "Maghrib iqama in 5 min")
        self.assertEqual(body, "Iqama at 7:04 PM.")

    def test_athan_notification_can_be_turned_off(self):
        self.settings.notify_at_athan = False
        self.assertIsNone(content(PrayerEvent("fajr", "athan", self.maghrib), self.settings, self.fmt))

    def test_notify_send_is_silent_unless_asked(self):
        self.assertIn("--hint=boolean:suppress-sound:true", notify_send_args("t", "b", False))
        self.assertIn("--hint=string:sound-name:message-new-instant", notify_send_args("t", "b", True))
        self.assertEqual(notify_send_args("t", "b", False)[-3:], ["--", "t", "b"])


class EventKeyTests(unittest.TestCase):
    def test_keys_are_per_prayer_per_day_in_the_place_zone(self):
        tz = ZoneInfo("America/Los_Angeles")
        late = make_instant(tz, 2026, 9, 29, 23, 30)
        self.assertEqual(PrayerEvent("isha", "iqama", late).key(tz), "isha-iqama-2026-09-29")
        self.assertEqual(PrayerEvent("isha", "iqamaReminder", late, 10).key(tz), "isha-reminder-2026-09-29")

    def test_fixed_iqama_before_the_athan_is_tomorrow(self):
        tz = ZoneInfo("Europe/London")
        athan = make_instant(tz, 2026, 6, 20, 23, 10)
        iqama = resolve_iqama(IqamaRule.fixed(0, 30), athan, tz)
        self.assertEqual(iqama, make_instant(tz, 2026, 6, 21, 0, 30))

    def test_skipped_wall_time_moves_forward(self):
        tz = ZoneInfo("America/Los_Angeles")
        # 02:30 does not exist on 8 March 2026; Foundation lands on 03:30 PDT.
        self.assertEqual(make_instant(tz, 2026, 3, 8, 2, 30), make_instant(tz, 2026, 3, 8, 3, 30))


if __name__ == "__main__":
    unittest.main()
