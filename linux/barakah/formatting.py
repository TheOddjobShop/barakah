"""Formatting shared by the tray, the menu and the athan window, so a time
never renders one way in one place and differently in another — the Linux
twin of PrayerFormatter in Theme.swift."""

from __future__ import annotations

from datetime import datetime

from . import hijri
from .engine import place_zone, system_timezone_identifier
from .model import PlaceSetting


class PrayerFormatter:
    def __init__(self, use_24_hour: bool, place: PlaceSetting):
        self.use_24_hour = use_24_hour
        self.place = place
        self.tz = place_zone(place)

    @property
    def zone_identifier(self) -> str:
        return self.place.time_zone_identifier or system_timezone_identifier()

    def time(self, ts: float) -> str:
        d = datetime.fromtimestamp(ts, self.tz)
        if self.use_24_hour:
            return d.strftime("%H:%M")
        hour = d.hour % 12 or 12
        return f"{hour}:{d.minute:02d} {'AM' if d.hour < 12 else 'PM'}"

    @staticmethod
    def countdown(interval: float) -> str:
        """"1h 12m", "12m", "48s" — the two most significant units."""
        total = max(0, int(_swift_round(interval)))
        hours, minutes, seconds = total // 3600, (total % 3600) // 60, total % 60
        if hours > 0:
            return f"{hours}h {minutes}m"
        if minutes > 0:
            return f"{minutes}m"
        return f"{seconds}s"

    @staticmethod
    def long_countdown(interval: float) -> str:
        total = max(0, int(_swift_round(interval)))
        hours, minutes = total // 3600, (total % 3600) // 60
        if hours == 0 and minutes == 0:
            return "in less than a minute"
        if hours == 0:
            return f"in {minutes} minute{'' if minutes == 1 else 's'}"
        if minutes == 0:
            return f"in {hours} hour{'' if hours == 1 else 's'}"
        return f"in {hours}h {minutes}m"

    def hijri_date(self, ts: float) -> str | None:
        return hijri.hijri_date(ts, self.zone_identifier)

    def gregorian_date(self, ts: float) -> str:
        d = datetime.fromtimestamp(ts, self.tz)
        return f"{d.strftime('%A')}, {d.day} {d.strftime('%B')}"


def _swift_round(x: float) -> float:
    import math
    return math.floor(x + 0.5) if x >= 0 else -math.floor(-x + 0.5)
