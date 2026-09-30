"""`barakah --times`: today's schedule on stdout, from the same settings and
engine the tray uses. Handy over ssh, and for checking a day against the Mac."""

from __future__ import annotations

import json
import time

from . import paths
from .engine import PrayerTimeEngine
from .formatting import PrayerFormatter
from .model import NAMES, SettingsData


def print_times() -> int:
    try:
        with open(paths.settings_file(), encoding="utf-8") as fh:
            settings = SettingsData.from_json(json.load(fh))
    except (OSError, ValueError):
        settings = SettingsData()
    schedule = PrayerTimeEngine().schedule(time.time(), settings)
    place = settings.active_place
    fmt = PrayerFormatter(settings.use_24_hour_clock, place)
    print(f"{place.name} ({place.short_coordinate_description}, {place.time_zone_identifier or 'system zone'})")
    print(f"{settings.calculation_method}, madhab {settings.madhab}, "
          f"high-latitude rule {settings.high_latitude_rule or 'method default'}")
    if schedule is None:
        print("No times can be calculated for this place today.")
        return 1
    print(fmt.gregorian_date(time.time()) + (f" · {fmt.hijri_date(time.time())}" if settings.show_hijri_date else ""))
    for p in schedule.prayers:
        iqama = f"   iqama {fmt.time(p.iqama)}" if p.iqama is not None else ""
        print(f"  {NAMES[p.kind]:<8} {fmt.time(p.athan):>8}{iqama}")
    return 0
