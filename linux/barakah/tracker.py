"""The prayer log and the prayer lock's rule — PrayerLog.swift and
PrayerLock.swift for Linux.

Each prayer owns a window: from its athan to the next prayer's (Fajr's ends at
sunrise, Isha's at the next Fajr). The log records what the user swore to for
a window; a window that ends with nothing recorded was missed. Missed is never
stored, only derived, so it is right whether or not the app was running when
the window closed.

The lock is derived the same way: it is due while a prayer's window is open,
its grace period has passed, and the log has nothing for it. Nothing here
fires; whoever asks gets the answer for that instant, so killing the app or
sleeping through the moment cannot skip it.

Pure: no I/O, no GLib. The log file itself is PrayerLogStore in store.py.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Optional

from .engine import PrayerTimeEngine, add_days, local, place_zone, start_of_day
from .model import PRAYERS, SettingsData

# What a user can record for a prayer. "prayed" is within its window, "qada"
# made up after it, "excused" not owed (travel combined, illness, haid).
PRAYED, QADA, EXCUSED = "prayed", "qada", "excused"
STATUSES = (PRAYED, QADA, EXCUSED)
# Derived, never stored.
MISSED, OPEN, UPCOMING, UNTRACKED = "missed", "open", "upcoming", "untracked"

# Days that count toward a streak: every prayer prayed on time, or not owed.
_KEEPS_STREAK = (PRAYED, EXCUSED)


def day_key(ts: float, tz) -> str:
    d = local(ts, tz)
    return f"{d.year:04d}-{d.month:02d}-{d.day:02d}"


# MARK: - The log


@dataclass(frozen=True)
class LogEntry:
    status: str
    at: float  # when it was recorded, Unix seconds

    def to_json(self) -> dict:
        return {"status": self.status, "at": self.at}

    @classmethod
    def from_json(cls, value: Any) -> Optional["LogEntry"]:
        if not isinstance(value, dict) or value.get("status") not in STATUSES:
            return None
        try:
            return cls(value["status"], float(value.get("at", 0)))
        except (TypeError, ValueError):
            return None


@dataclass
class PrayerLog:
    """`since` is when tracking began: a prayer whose window opened before it
    is neither prayed nor missed, so the first day is not a page of failures."""
    since: float
    days: dict = field(default_factory=dict)  # "YYYY-MM-DD" -> {prayer: LogEntry}

    def entry(self, key: str, kind: str) -> Optional[LogEntry]:
        return self.days.get(key, {}).get(kind)

    def record(self, key: str, kind: str, status: str, at: float) -> None:
        if status not in STATUSES:
            raise ValueError(f"unknown status {status!r}")
        self.days.setdefault(key, {})[kind] = LogEntry(status, at)

    def clear(self, key: str, kind: str) -> None:
        day = self.days.get(key)
        if day is not None:
            day.pop(kind, None)
            if not day:
                del self.days[key]

    def to_json(self) -> dict:
        return {
            "version": 1,
            "since": self.since,
            "days": {k: {p: e.to_json() for p, e in sorted(v.items())} for k, v in sorted(self.days.items())},
        }

    @classmethod
    def from_json(cls, data: Any) -> "PrayerLog":
        if not isinstance(data, dict):
            raise ValueError("prayer log must be a JSON object")
        since = float(data.get("since", 0))
        days: dict = {}
        raw_days = data.get("days") if isinstance(data.get("days"), dict) else {}
        for key, prayers in raw_days.items():
            if not isinstance(prayers, dict):
                continue
            entries = {p: e for p, e in ((p, LogEntry.from_json(v)) for p, v in prayers.items())
                       if p in PRAYERS and e is not None}
            if entries:
                days[str(key)] = entries
        return cls(since, days)


# MARK: - Windows


@dataclass(frozen=True)
class PrayerWindow:
    kind: str
    day: str          # the place-day the prayer belongs to, "YYYY-MM-DD"
    start: float      # the athan, with its fine adjustment
    end: float        # the next window's start; sunrise for Fajr
    iqama: Optional[float] = None

    def contains(self, ts: float) -> bool:
        return self.start <= ts < self.end


def _boundaries(settings: SettingsData) -> SettingsData:
    # Sunrise ends Fajr whether or not the list shows it.
    if settings.show_sunrise:
        return settings
    copy = settings.copy()
    copy.show_sunrise = True
    return copy


def windows(day: float, settings: SettingsData, engine: Optional[PrayerTimeEngine] = None) -> list:
    """The five windows of the place-day containing `day`, in order."""
    engine = engine or PrayerTimeEngine()
    settings = _boundaries(settings)
    tz = place_zone(settings.active_place)
    today = engine.schedule(day, settings)
    if today is None:
        return []
    tomorrow = engine.schedule(add_days(today.day, 1, tz), settings)
    marks = list(today.prayers)
    following = tomorrow.prayer("fajr") if tomorrow else None
    key = day_key(today.day, tz)
    out = []
    for index, prayer in enumerate(marks):
        if prayer.kind not in PRAYERS:
            continue
        nxt = marks[index + 1] if index + 1 < len(marks) else following
        if nxt is None:
            continue
        out.append(PrayerWindow(prayer.kind, key, prayer.athan, nxt.athan, prayer.iqama))
    return out


def window_at(now: float, settings: SettingsData, engine: Optional[PrayerTimeEngine] = None) -> Optional[PrayerWindow]:
    """The prayer whose time it is: yesterday's Isha before Fajr, nothing
    between sunrise and Dhuhr."""
    engine = engine or PrayerTimeEngine()
    tz = place_zone(settings.active_place)
    for day in (now, add_days(start_of_day(now, tz), -1, tz)):
        for window in windows(day, settings, engine):
            if window.contains(now):
                return window
    return None


def status(log: PrayerLog, window: PrayerWindow, now: float) -> str:
    entry = log.entry(window.day, window.kind)
    if entry is not None:
        return entry.status
    if window.start < log.since:
        return UNTRACKED
    if now < window.start:
        return UPCOMING
    if now < window.end:
        return OPEN
    return MISSED


def status_for_record(window: PrayerWindow, now: float) -> str:
    """What "I prayed it" means right now: on time inside the window, qada after."""
    return PRAYED if now < window.end else QADA


# MARK: - The lock


@dataclass(frozen=True)
class LockState:
    """`active` is the window the screen is locked for, if any. `next_at` is
    when the next lock would begin if nothing is logged before then — for a
    countdown, and for nothing else."""
    active: Optional[PrayerWindow]
    next_at: Optional[float]
    next_window: Optional[PrayerWindow] = None


def lock_state(now: float, settings: SettingsData, log: PrayerLog,
               engine: Optional[PrayerTimeEngine] = None) -> LockState:
    lock = settings.lock
    if not lock.enabled:
        return LockState(None, None)
    engine = engine or PrayerTimeEngine()
    tz = place_zone(settings.active_place)
    today = start_of_day(now, tz)
    candidates = []
    for day in (add_days(today, -1, tz), now, add_days(today, 1, tz)):
        candidates.extend(windows(day, settings, engine))

    active = None
    upcoming: list = []
    for window in candidates:
        rule = lock.rule(window.kind)
        if not rule.enabled or window.start < log.since or log.entry(window.day, window.kind) is not None:
            continue
        locks_at = window.start + rule.grace_minutes * 60
        if locks_at >= window.end:
            continue
        if locks_at <= now < window.end:
            active = window
        elif locks_at > now:
            upcoming.append((locks_at, window))
    upcoming.sort(key=lambda pair: pair[0])
    nxt = upcoming[0] if upcoming else (None, None)
    return LockState(active, nxt[0], nxt[1])


# MARK: - History


@dataclass(frozen=True)
class DayRecord:
    day: str
    statuses: dict  # prayer -> status


def history(log: PrayerLog, settings: SettingsData, now: float, days: int,
            engine: Optional[PrayerTimeEngine] = None) -> list:
    """The last `days` place-days, newest first, each prayer with its status.

    A year of this backs the heatmap, so days whose every window has ended —
    everything before yesterday — are settled from the log alone: their
    prayers were missed unless recorded, or untracked if the day ended before
    tracking began. Only the day tracking began on, yesterday and today need
    their prayer times."""
    engine = engine or PrayerTimeEngine()
    tz = place_zone(settings.active_place)
    today = start_of_day(now, tz)
    out = []
    for offset in range(days):
        day = add_days(today, -offset, tz)
        key = day_key(day, tz)
        derived = _settled(day, log.since, now, tz)
        if derived is not None:
            statuses = {}
            for kind in PRAYERS:
                entry = log.entry(key, kind)
                statuses[kind] = entry.status if entry else derived
            out.append(DayRecord(key, statuses))
            continue
        found = {w.kind: w for w in windows(day, settings, engine)}
        statuses = {}
        for kind in PRAYERS:
            window = found.get(kind)
            if window is None:
                entry = log.entry(key, kind)
                statuses[kind] = entry.status if entry else UNTRACKED
            else:
                statuses[kind] = status(log, window, now)
        out.append(DayRecord(key, statuses))
    return out


def _settled(day: float, since: float, now: float, tz) -> Optional[str]:
    """What an unrecorded prayer of `day` is without computing its times, if
    that can be known: every window of a day has ended by the start of the
    day after next (Isha ends at the next Fajr)."""
    if add_days(day, 2, tz) > now:
        return None
    if add_days(day, 1, tz) <= since:
        return UNTRACKED
    if day >= since:
        return MISSED
    return None  # tracking began during this day


# MARK: - Heat

# A day's heat is how much of it was kept: prayers on time and prayers not
# owed count whole, a prayer made up later counts half.
HEAT_LEVELS = 4


@dataclass(frozen=True)
class Heat:
    score: float     # 0…5
    level: int       # 0 (nothing kept) … 4 (all five on time)
    on_time: int
    made_up: int
    excused: int
    missed: int


def heat(record: DayRecord) -> Optional[Heat]:
    """None for a day with nothing tracked."""
    values = list(record.statuses.values())
    if all(v == UNTRACKED for v in values):
        return None
    on_time = values.count(PRAYED)
    made_up = values.count(QADA)
    excused = values.count(EXCUSED)
    score = on_time + excused + made_up / 2
    if score <= 0:
        level = 0
    elif score <= 2:
        level = 1
    elif score <= 3.5:
        level = 2
    elif score < len(PRAYERS):
        level = 3
    else:
        level = 4
    return Heat(score, level, on_time, made_up, excused, values.count(MISSED))


def streak(records: list) -> int:
    """Consecutive complete days, newest first. Today counts once it is
    complete, and does not break the streak while it is still under way."""
    count = 0
    for index, record in enumerate(records):
        values = list(record.statuses.values())
        if all(v in _KEEPS_STREAK for v in values):
            count += 1
            continue
        if index == 0 and all(v in _KEEPS_STREAK + (OPEN, UPCOMING) for v in values):
            continue
        break
    return count


def longest_streak(records: list) -> int:
    """The longest run of complete days anywhere in the records."""
    best = run = 0
    for record in records:
        if all(v in _KEEPS_STREAK for v in record.statuses.values()):
            run += 1
            best = max(best, run)
        else:
            run = 0
    return best


def on_time_ratio(records: list) -> Optional[float]:
    """Prayed on time over prayers owed, across the records; None if none were owed."""
    owed = prayed = 0
    for record in records:
        for value in record.statuses.values():
            if value in (PRAYED, QADA, MISSED):
                owed += 1
                prayed += value == PRAYED
    return prayed / owed if owed else None

