"""Settings plus a date in, concrete prayer times out.

A port of Sources/Barakah/Services/PrayerTimeEngine.swift and DaySchedule.swift.
Pure and synchronous: no state, no I/O beyond reading the system timezone.
Instants are float Unix seconds; calendar arithmetic happens in the *place's*
timezone, the way the Swift engine uses a Gregorian calendar set to it.
"""

from __future__ import annotations

import math
import os
from dataclasses import dataclass
from datetime import date as _date, datetime, timedelta
from typing import Optional
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from . import adhan
from .model import PRAYER_KINDS, SettingsData, is_prayer, pauses_players, PlaceSetting, IqamaRule

# MARK: - Timezones


def system_timezone_identifier() -> str:
    """The machine's IANA zone, e.g. "America/Los_Angeles"."""
    tz = os.environ.get("TZ", "").lstrip(":")
    if tz and _zone(tz) is not None:
        return tz
    try:
        target = os.path.realpath("/etc/localtime")
        marker = "/zoneinfo/"
        if marker in target:
            name = target.split(marker, 1)[1]
            if _zone(name) is not None:
                return name
    except OSError:
        pass
    try:
        with open("/etc/timezone", encoding="utf-8") as fh:
            name = fh.read().strip()
            if _zone(name) is not None:
                return name
    except OSError:
        pass
    return "UTC"


def _zone(identifier: str) -> Optional[ZoneInfo]:
    if not identifier:
        return None
    try:
        return ZoneInfo(identifier)
    except (ZoneInfoNotFoundError, ValueError, OSError):
        return None


def place_zone(place: PlaceSetting) -> ZoneInfo:
    """`TimeZone(identifier:) ?? .current`."""
    return _zone(place.time_zone_identifier) or _zone(system_timezone_identifier()) or ZoneInfo("UTC")


def local(ts: float, tz: ZoneInfo) -> datetime:
    return datetime.fromtimestamp(ts, tz)


def make_instant(tz: ZoneInfo, y: int, m: int, d: int, hh: int = 0, mm: int = 0, ss: int = 0) -> float:
    """A wall-clock time in `tz` as an instant, resolved the way Foundation's
    Calendar resolves it: an ambiguous time takes its first occurrence, and a
    time skipped by a DST jump moves forward by the size of the jump — which
    is what `fold=0` does with a skipped time, since it applies the offset
    from before the transition."""
    return datetime(y, m, d, hh, mm, ss, tzinfo=tz, fold=0).timestamp()


def start_of_day(ts: float, tz: ZoneInfo) -> float:
    d = local(ts, tz)
    return make_instant(tz, d.year, d.month, d.day)


def add_days(ts: float, days: int, tz: ZoneInfo) -> float:
    """`calendar.date(byAdding: .day, value:, to:)`: same wall time, another day."""
    d = local(ts, tz)
    target = _date(d.year, d.month, d.day) + timedelta(days=days)
    return make_instant(tz, target.year, target.month, target.day, d.hour, d.minute, d.second) + (ts - math.floor(ts))


def ymd(ts: float, tz: ZoneInfo) -> tuple[int, int, int]:
    d = local(ts, tz)
    return (d.year, d.month, d.day)


def is_friday(ts: float, tz: ZoneInfo) -> bool:
    return local(ts, tz).weekday() == 4


def resolve_iqama(rule: IqamaRule, athan: float, tz: ZoneInfo) -> Optional[float]:
    """`IqamaRule.resolve(athan:calendar:)`."""
    if rule.kind == "offset":
        return athan + rule.minutes * 60
    if rule.kind == "fixed":
        y, m, d = ymd(athan, tz)
        fixed = make_instant(tz, y, m, d, rule.hour, rule.minute, 0)
        # A fixed time before the adhan belongs to the next day (only
        # realistically possible for Isha near midnight).
        if fixed < athan:
            return add_days(fixed, 1, tz)
        return fixed
    return None


# MARK: - Schedules


@dataclass(frozen=True)
class ScheduledPrayer:
    kind: str
    athan: float
    iqama: Optional[float]


@dataclass(frozen=True)
class DaySchedule:
    day: float
    place: PlaceSetting
    prayers: tuple
    middle_of_the_night: Optional[float] = None
    last_third_of_the_night: Optional[float] = None

    def prayer(self, kind: str) -> Optional[ScheduledPrayer]:
        return next((p for p in self.prayers if p.kind == kind), None)

    def next_athan(self, after: float) -> Optional[ScheduledPrayer]:
        return next((p for p in self.prayers if p.athan > after), None)

    def current_prayer(self, at: float) -> Optional[ScheduledPrayer]:
        current = None
        for p in self.prayers:
            if p.athan <= at:
                current = p
        return current


@dataclass(frozen=True)
class PrayerEvent:
    """`athan`, `iqamaReminder` (with `minutes_before`) or `iqama`."""
    prayer: str
    kind: str
    fire_at: float
    minutes_before: int = 0

    def key(self, tz: ZoneInfo) -> str:
        """Identifies "this prayer's athan, today" rather than the exact instant,
        so a recomputation that moves a prayer by a second cannot make an event
        that just fired look unfired. See DaySchedule.swift."""
        y, m, d = ymd(self.fire_at, tz)
        tag = {"athan": "athan", "iqamaReminder": "reminder", "iqama": "iqama"}[self.kind]
        return f"{self.prayer}-{tag}-{y:04d}-{m:02d}-{d:02d}"

    def day(self, tz: ZoneInfo) -> float:
        return start_of_day(self.fire_at, tz)


class PrayerTimeEngine:
    def schedule(self, at: float, settings: SettingsData) -> Optional[DaySchedule]:
        place = settings.active_place
        tz = place_zone(place)
        day = ymd(at, tz)
        times = adhan.PrayerTimes.compute(place.latitude, place.longitude, day, settings.calculation_parameters)
        if times is None:
            return None
        day_start = make_instant(tz, *day)
        friday = is_friday(day_start, tz)

        scheduled = []
        for kind in PRAYER_KINDS:
            if kind == "sunrise" and not settings.show_sunrise:
                continue
            base = times.time(kind)
            athan = base + settings.config(kind).athan_adjustment_minutes * 60
            iqama = resolve_iqama(settings.effective_iqama_rule(kind, friday), athan, tz) if is_prayer(kind) else None
            scheduled.append(ScheduledPrayer(kind, athan, iqama))
        scheduled.sort(key=lambda p: p.athan)

        sunnah = adhan.SunnahTimes.compute(times)
        return DaySchedule(
            day=day_start,
            place=place,
            prayers=tuple(scheduled),
            middle_of_the_night=sunnah.middle_of_the_night if sunnah else None,
            last_third_of_the_night=sunnah.last_third_of_the_night if sunnah else None,
        )

    def schedules(self, start: float, count: int, settings: SettingsData) -> list:
        tz = place_zone(settings.active_place)
        out = []
        for offset in range(max(0, count)):
            s = self.schedule(add_days(start, offset, tz), settings)
            if s is not None:
                out.append(s)
        return out

    def events(self, after: float, horizon: float, settings: SettingsData) -> list:
        """Every event that should fire in `(after, after + horizon]`."""
        tz = place_zone(settings.active_place)
        end = after + horizon
        # Start a day early: a late Isha iqama or reminder can belong to yesterday.
        first_day = add_days(after, -1, tz)
        day_count = int(math.ceil(horizon / 86_400)) + 2

        events = []
        for day in self.schedules(first_day, day_count, settings):
            friday = is_friday(day.day, tz)
            for prayer in day.prayers:
                if not is_prayer(prayer.kind):
                    continue
                config = settings.config(prayer.kind)
                if config.athan_enabled or settings.notify_at_athan or pauses_players(config.media_mode):
                    events.append(PrayerEvent(prayer.kind, "athan", prayer.athan))
                if prayer.iqama is None:
                    continue
                minutes = settings.effective_reminder_minutes(prayer.kind, friday)
                if minutes > 0:
                    reminder_at = prayer.iqama - minutes * 60
                    if reminder_at > prayer.athan:
                        events.append(PrayerEvent(prayer.kind, "iqamaReminder", reminder_at, minutes))
                if config.iqama_alert_enabled:
                    events.append(PrayerEvent(prayer.kind, "iqama", prayer.iqama))

        events = [e for e in events if after < e.fire_at <= end]
        events.sort(key=lambda e: e.fire_at)
        return events
