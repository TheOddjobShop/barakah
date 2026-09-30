"""The Linux engine must agree with the Swift engine to the second.

`parity.json` is written by Tests/BarakahTests/LinuxParityTests.swift, which
runs the macOS app's own PrayerTimeEngine over adhan-swift. Regenerate it
there after any deliberate change to the calculation.
"""

import json
import os
import unittest

from barakah.engine import PrayerTimeEngine
from barakah.model import PlaceSetting, SettingsData

FIXTURE = os.path.join(os.path.dirname(__file__), "parity.json")


def encode_schedule(schedule):
    if schedule is None:
        return None
    base = schedule.day
    return {
        "day": base,
        "prayers": [[p.kind, p.athan - base, None if p.iqama is None else p.iqama - base]
                    for p in schedule.prayers],
        "sunnah": [
            None if schedule.middle_of_the_night is None else schedule.middle_of_the_night - base,
            None if schedule.last_third_of_the_night is None else schedule.last_third_of_the_night - base,
        ],
    }


def encode_events(events):
    return sorted([e.prayer, e.kind, e.minutes_before, e.fire_at] for e in events)


class ParityTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with open(FIXTURE, encoding="utf-8") as fh:
            cls.fixture = json.load(fh)
        cls.engine = PrayerTimeEngine()

    def test_grid(self):
        places = [PlaceSetting.from_json(p) for p in self.fixture["places"]]
        mismatches = []
        for entry in self.fixture["grid"]:
            settings = SettingsData()
            settings.location_mode = "manual"
            settings.manual_place = places[entry["place"]]
            settings.calculation_method = entry["method"]
            settings.madhab = entry["madhab"]
            settings.high_latitude_rule = entry["rule"]
            got = encode_schedule(self.engine.schedule(entry["at"], settings))
            if got != entry["schedule"]:
                mismatches.append((settings.manual_place.name, entry["method"], entry["madhab"],
                                   entry["rule"], entry["at"], entry["schedule"], got))
        self.assertEqual(len(self.fixture["grid"]), 12 * 8 * 13)
        self.assertFalse(mismatches, "\n".join(map(str, mismatches[:5])) + f"\n{len(mismatches)} mismatches")

    def test_configured_settings(self):
        for entry in self.fixture["rich"]:
            settings = SettingsData.from_json(entry["settings"])
            with self.subTest(place=settings.active_place.name, at=entry["at"]):
                self.assertEqual(encode_schedule(self.engine.schedule(entry["at"], settings)), entry["schedule"])
                events = self.engine.events(entry["at"], 3 * 86_400, settings)
                self.assertEqual(encode_events(events), sorted(entry["events"]))

    def test_settings_round_trip(self):
        # What the Swift app wrote must come back out unchanged, so a
        # settings.json can move between a Mac and a Linux machine.
        for entry in self.fixture["rich"]:
            settings = SettingsData.from_json(entry["settings"])
            self.assertEqual(settings.to_json(), entry["settings"])


if __name__ == "__main__":
    unittest.main()
