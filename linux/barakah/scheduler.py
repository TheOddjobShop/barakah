"""Fires prayer events at the right moment — Scheduler.swift on GLib.

The failure modes this exists to survive are the same as on macOS:

- Suspend. GLib timeouts run on the monotonic clock, which stops while the
  machine sleeps. logind's PrepareForSleep(false) triggers a rebuild on
  resume, and anything missed is skipped, not replayed — an adhan for a
  prayer that passed two hours ago is worse than no adhan.
- Clock and timezone changes. The heartbeat compares the wall clock with the
  monotonic clock and rebuilds on a jump; timedated's Timezone property is
  watched as well.
- Day rollover. The horizon is re-derived so tomorrow's Fajr is armed before
  tonight's Isha has finished.
- A timer that never fires. A slow heartbeat independently checks for events
  that came due, so a dropped timer costs seconds, not a prayer.
"""

from __future__ import annotations

import logging
import time
from typing import Callable, Optional

from gi.repository import Gio, GLib

from .engine import DaySchedule, PrayerEvent, PrayerTimeEngine, ScheduledPrayer, add_days, place_zone, start_of_day
from .model import SettingsData, is_prayer

log = logging.getLogger("barakah.scheduler")

GRACE = 90.0
HORIZON = 3 * 86_400.0
HEARTBEAT = 30


class Scheduler:
    def __init__(self, settings: SettingsData, now: Optional[float] = None):
        self.settings = settings
        self.engine = PrayerTimeEngine()
        self.upcoming: list[PrayerEvent] = []
        self.today: Optional[DaySchedule] = None
        self.tomorrow: Optional[DaySchedule] = None
        self.next_prayer: Optional[ScheduledPrayer] = None
        self.on_event: Optional[Callable[[PrayerEvent], None]] = None
        self.on_rebuild: Optional[Callable[[], None]] = None
        self._fired: dict[str, float] = {}
        self._started_at = now if now is not None else time.time()
        self._timer = 0
        self._heartbeat = 0
        self._offset = time.time() - time.monotonic()
        self._subscriptions: list[tuple[Gio.DBusConnection, int]] = []
        self.rebuild(now)

    @property
    def _tz(self):
        return place_zone(self.settings.active_place)

    def start(self) -> None:
        self._install_observers()
        self._start_heartbeat()

    def invalidate(self) -> None:
        for source in (self._timer, self._heartbeat):
            if source:
                GLib.source_remove(source)
        self._timer = self._heartbeat = 0
        for connection, sub in self._subscriptions:
            connection.signal_unsubscribe(sub)
        self._subscriptions.clear()

    def update(self, settings: SettingsData) -> None:
        self.settings = settings
        self.rebuild()

    def rebuild(self, now: Optional[float] = None) -> None:
        now = time.time() if now is None else now
        tz = self._tz
        self.today = self.engine.schedule(now, self.settings)
        self.tomorrow = self.engine.schedule(add_days(now, 1, tz), self.settings)
        self.next_prayer = None
        if self.today is not None:
            self.next_prayer = next((p for p in self.today.prayers if p.athan > now and is_prayer(p.kind)), None)
        if self.next_prayer is None and self.tomorrow is not None:
            self.next_prayer = next((p for p in self.tomorrow.prayers if is_prayer(p.kind)), None)

        self.upcoming = self.engine.events(now - GRACE, HORIZON, self.settings)

        # Fired markers are kept for two days and pruned by day, so a
        # backwards clock step cannot re-admit an event and sound it again.
        horizon = add_days(start_of_day(now, tz), -2, tz)
        self._fired = {k: day for k, day in self._fired.items() if day >= horizon}

        self._arm(now)
        if self.on_rebuild:
            self.on_rebuild()

    def _check_due(self, now: Optional[float] = None) -> None:
        now = time.time() if now is None else now
        tz = self._tz
        did_fire = False
        for event in self.upcoming:
            key = event.key(tz)
            if key in self._fired:
                continue
            if event.fire_at > now:
                break
            self._fired[key] = event.day(tz)
            # Anything from before this process started belongs to a previous
            # run; replaying it would sound an adhan the user already heard.
            if event.fire_at < self._started_at:
                log.info("skipping %s, predates launch", key)
                continue
            lateness = now - event.fire_at
            if lateness > GRACE:
                log.info("skipping %s, %ds late", key, int(lateness))
                continue
            log.info("firing %s", key)
            if self.on_event:
                self.on_event(event)
            did_fire = True

        day_rolled = self.today is None or start_of_day(now, tz) != self.today.day
        next_passed = self.next_prayer is None or self.next_prayer.athan <= now
        if did_fire or day_rolled or next_passed:
            self.rebuild(now)
        else:
            self._arm(now)

    def _arm(self, now: float) -> None:
        if self._timer:
            GLib.source_remove(self._timer)
            self._timer = 0
        tz = self._tz
        pending = [e for e in self.upcoming if e.key(tz) not in self._fired]
        if any(e.fire_at <= now for e in pending):
            # Due already: check on the next main-loop pass rather than
            # waiting for the heartbeat and drifting past the grace window.
            self._timer = GLib.timeout_add(50, self._on_timer)
            return
        nxt = next((e for e in pending if e.fire_at > now), None)
        if nxt is None:
            return
        # Re-derive at least hourly; a timer armed days out is more likely to
        # be invalidated by suspend or a clock change than to fire.
        delay = min(nxt.fire_at - now, 3600.0)
        self._timer = GLib.timeout_add(max(1, int(delay * 1000) + 20), self._on_timer)

    def _on_timer(self) -> bool:
        self._timer = 0
        self._check_due()
        return False

    def _start_heartbeat(self) -> None:
        if not self._heartbeat:
            self._heartbeat = GLib.timeout_add_seconds(HEARTBEAT, self._on_heartbeat)

    def _on_heartbeat(self) -> bool:
        offset = time.time() - time.monotonic()
        jumped = abs(offset - self._offset) > 5
        self._offset = offset
        if jumped:
            log.info("wall clock jumped; rebuilding")
            self.rebuild()
        else:
            self._check_due()
        return True

    # MARK: - System observers

    def _install_observers(self) -> None:
        try:
            system = Gio.bus_get_sync(Gio.BusType.SYSTEM, None)
        except GLib.Error as error:
            log.warning("no system bus, relying on the heartbeat: %s", error.message)
            return
        sleep = system.signal_subscribe(
            "org.freedesktop.login1", "org.freedesktop.login1.Manager", "PrepareForSleep",
            "/org/freedesktop/login1", None, Gio.DBusSignalFlags.NONE, self._on_sleep)
        timezone = system.signal_subscribe(
            "org.freedesktop.timedate1", "org.freedesktop.DBus.Properties", "PropertiesChanged",
            "/org/freedesktop/timedate1", None, Gio.DBusSignalFlags.NONE, self._on_timezone)
        self._subscriptions += [(system, sleep), (system, timezone)]

    def _on_sleep(self, _conn, _sender, _path, _iface, _signal, params) -> None:
        going_to_sleep = params.unpack()[0]
        if not going_to_sleep:
            log.info("resumed from suspend; rebuilding")
            self._offset = time.time() - time.monotonic()
            self.rebuild()

    def _on_timezone(self, _conn, _sender, _path, _iface, _signal, params) -> None:
        # zoneinfo reads /etc/localtime afresh through system_timezone_identifier.
        self.rebuild()
