"""The one object that knows what an event means — AppState.swift for Linux.

The scheduler knows when things happen, the audio service how to make sound,
the media controller how to silence players. This is where those become "at
Maghrib, pause the browser tab, play the adhan, and put it back when it ends".
"""

from __future__ import annotations

import logging
import time
from typing import Callable, Optional

from gi.repository import GLib

from . import autostart, tracker
from .audio import AthanLibrary, AudioService, Chime, Normalizer
from .engine import PrayerEvent, ScheduledPrayer, add_days, place_zone, start_of_day
from .location import LocationService
from .media import MediaController
from .model import PRAYERS, PlaceSetting, SettingsData, mutes_output, pauses_players
from .notify import NotificationService
from .scheduler import Scheduler
from .store import PrayerLogStore, SettingsStore
from .tracker import LockState, PrayerWindow

log = logging.getLogger("barakah.app")

# How long a pause lasts when a prayer silences media without sounding an
# athan — about the length of a spoken adhan.
SILENT_ATHAN_LENGTH = 120

# How often the prayer lock is re-derived. It is state, not an event: asking
# often is what makes a restart, a resume or a clock change bring it back.
LOCK_CHECK_SECONDS = 2


class AppState:
    def __init__(self, store: Optional[SettingsStore] = None, prayer_log: Optional[PrayerLogStore] = None):
        self.store = store or SettingsStore()
        self.prayer_log = prayer_log or PrayerLogStore()
        self.lock = LockState(None, None)
        self.scheduler = Scheduler(self.store.data)
        self.audio = AudioService()
        self.media = MediaController()
        self.notifications = NotificationService()
        self.location = LocationService()

        # Prayers silenced for a day, each mapped to the day (start of day in
        # the place's zone) it was silenced for.
        self.muted_days: dict[str, float] = {}
        self.muted_until: Optional[float] = None
        self.interruption_summary: Optional[str] = None

        self._resume_source = 0
        self._resume_deferred = False
        self._lock_source = 0
        self._last_notification_refresh: Optional[float] = None
        self._listeners: list[Callable[[], None]] = []

        self.scheduler.on_event = self._handle
        self.audio.on_finish = self._athan_finished
        self.audio.on_change = self.changed
        self.location.on_resolve = self._location_resolved
        self.location.on_change = self.changed

    @property
    def settings(self) -> SettingsData:
        return self.store.data

    def subscribe(self, listener: Callable[[], None]) -> None:
        self._listeners.append(listener)

    def unsubscribe(self, listener: Callable[[], None]) -> None:
        if listener in self._listeners:
            self._listeners.remove(listener)

    def changed(self) -> None:
        for listener in list(self._listeners):
            listener()

    @property
    def _start_of_place_day(self) -> float:
        return start_of_day(time.time(), place_zone(self.settings.active_place))

    def start(self) -> None:
        # A previous run may have died mid-athan with other audio muted.
        self.media.muter.recover_if_needed()
        Chime.warm()
        Normalizer.warm([p for p in AthanLibrary.installed() + AthanLibrary.bundled()])
        # The notification horizon is three days, so something must roll it
        # forward on a machine that simply stays logged in.
        self.scheduler.on_rebuild = lambda: self.refresh_notifications()
        self.scheduler.start()
        if self.settings.location_mode == "automatic":
            self.location.refresh()
        if self.settings.launch_at_login != autostart.is_enabled():
            autostart.set_enabled(self.settings.launch_at_login)
        self.refresh_notifications(force=True)
        self.scheduler.rebuild()
        self.check_lock()
        self._lock_source = GLib.timeout_add_seconds(LOCK_CHECK_SECONDS, lambda: (self.check_lock(), True)[1])

    def shutdown(self) -> None:
        if self._lock_source:
            GLib.source_remove(self._lock_source)
            self._lock_source = 0
        self.audio.stop(notify=False)
        # Muting must never outlive the app; paused players are left paused.
        if self.media.active is not None and self.media.active.muted_output:
            self.media.muter.restore()
        self.scheduler.invalidate()
        self.store.flush()

    # MARK: - Settings

    def update_settings(self, mutate: Callable[[SettingsData], None]) -> None:
        previous_login = self.settings.launch_at_login
        self.store.update(mutate)
        if self.settings.launch_at_login != previous_login:
            autostart.set_enabled(self.settings.launch_at_login)
        self._propagate()

    def reset_settings(self) -> None:
        self.store.reset_to_defaults()
        autostart.set_enabled(self.settings.launch_at_login)
        self._propagate()

    def update_config(self, kind: str, mutate) -> None:
        self.store.update_config(kind, mutate)
        self._propagate()

    def _propagate(self) -> None:
        self.scheduler.update(self.settings)
        self.refresh_notifications(force=True)
        self.check_lock(notify=False)
        self.changed()

    def refresh_notifications(self, force: bool = False) -> None:
        """Rewrite the pending notifications. Unforced calls — every rebuild —
        are throttled to six hours; settings edits, day changes and silencing
        force it."""
        now = time.time()
        if not force and self._last_notification_refresh and now - self._last_notification_refresh < 6 * 3600:
            return
        self._last_notification_refresh = now
        muted_days = dict(self.muted_days)
        muted_until = self.muted_until
        place_day = self._start_of_place_day

        def suppressed(prayer: str, fire_at: float) -> bool:
            if muted_until is not None and fire_at <= muted_until:
                return True
            return muted_days.get(prayer) == place_day

        self.notifications.reschedule(self.settings.copy(), now, suppressed)

    def _location_resolved(self, place: PlaceSetting) -> None:
        existing = self.settings.resolved_place
        # Sub-kilometre jitter is noise: times move about a minute per 20 km.
        if (existing is not None and abs(existing.latitude - place.latitude) < 0.01
                and abs(existing.longitude - place.longitude) < 0.01
                and existing.time_zone_identifier == place.time_zone_identifier):
            return
        self.update_settings(lambda s: setattr(s, "resolved_place", place))
        log.info("location resolved: %s", place.name)

    # MARK: - Events

    def _handle(self, event: PrayerEvent) -> None:
        if self.is_suppressed(event.prayer):
            log.info("suppressed %s", event.prayer)
            return
        # Without systemd timers the running app posts notifications itself.
        self.notifications.post_now(event, self.settings)
        if event.kind == "athan":
            self._start_athan(event.prayer)

    def _start_athan(self, prayer: str) -> None:
        config = self.settings.config(prayer)
        self._cancel_resume()
        # Media is silenced before the adhan starts, so the two never overlap.
        if pauses_players(config.media_mode) or mutes_output(config.media_mode):
            interruption = self.media.interrupt(config.media_mode, self.settings)
            self.interruption_summary = interruption.summary
        else:
            self.interruption_summary = None
        # "Enabled" but Silent makes no more sound than disabled.
        if config.athan_enabled and not self.settings.sound(prayer).is_silent:
            self.audio.play(prayer, self.settings)
        else:
            self._athan_finished(prayer, SILENT_ATHAN_LENGTH)
        self.changed()

    def test_athan(self, prayer: str = "") -> None:
        """The athan moment on demand, exactly as the scheduler would run it,
        for checking sound and media behaviour without waiting for a prayer."""
        if prayer not in PRAYERS:
            nxt = self.next_prayer
            prayer = nxt.kind if nxt is not None else "dhuhr"
        log.info("testing the athan for %s", prayer)
        self._start_athan(prayer)

    def stop_athan(self) -> None:
        self.audio.stop()

    def _athan_finished(self, prayer: str, silent_length: float = 0) -> None:
        if self.media.active is None:
            self.interruption_summary = None
            self.changed()
            return
        mode = self.settings.resume_mode
        if mode.kind == "never":
            self.media.forget()
            self.interruption_summary = None
        elif mode.kind == "afterAthan":
            if silent_length > 0:
                self._schedule_resume(silent_length)
            else:
                self.resume_media_now()
        elif mode.kind == "afterMinutes":
            self._schedule_resume(mode.minutes * 60 + silent_length)
        elif mode.kind == "afterIqama":
            today = self.scheduler.today
            scheduled = today.prayer(prayer) if today else None
            iqama = scheduled.iqama if scheduled else None
            delay = max(0.0, iqama - time.time()) if iqama is not None else silent_length
            self._schedule_resume(max(delay, silent_length))
        self.changed()

    def _schedule_resume(self, delay: float) -> None:
        self._cancel_resume()

        def fire() -> bool:
            self._resume_source = 0
            if self.lock.active is not None:
                # Nothing plays under the prayer lock; resume once it lifts.
                self._resume_deferred = True
                return False
            self.media.resume()
            self.interruption_summary = None
            self.changed()
            return False

        self._resume_source = GLib.timeout_add(max(0, int(delay * 1000)), fire)

    def _cancel_resume(self) -> None:
        if self._resume_source:
            GLib.source_remove(self._resume_source)
            self._resume_source = 0

    def resume_media_now(self) -> None:
        self._cancel_resume()
        self._resume_deferred = False
        self.media.resume()
        self.interruption_summary = None
        self.changed()

    # MARK: - Silencing

    def is_muted_today(self, prayer: str) -> bool:
        return self.muted_days.get(prayer) == self._start_of_place_day

    def toggle_mute_today(self, prayer: str) -> None:
        if self.is_muted_today(prayer):
            self.muted_days.pop(prayer, None)
        else:
            self.muted_days[prayer] = self._start_of_place_day
        self.refresh_notifications(force=True)
        self.changed()

    def mute(self, duration: Optional[float]) -> None:
        """Silence every athan for a while — a meeting, a flight, a cinema."""
        self.muted_until = time.time() + duration if duration is not None else None
        if self.audio.is_playing:
            self.audio.stop()
        self.refresh_notifications(force=True)
        self.changed()

    @property
    def is_globally_muted(self) -> bool:
        return self.muted_until is not None and self.muted_until > time.time()

    def is_suppressed(self, prayer: str) -> bool:
        return self.is_globally_muted or self.is_muted_today(prayer)

    def seconds_until_tomorrow(self) -> float:
        tz = place_zone(self.settings.active_place)
        return add_days(start_of_day(time.time(), tz), 1, tz) - time.time()

    # MARK: - Prayer tracker and lock

    def check_lock(self, notify: bool = True) -> None:
        state = tracker.lock_state(time.time(), self.settings, self.prayer_log.log, self.scheduler.engine)
        paused = self.media.pause_playing(self.settings) if state.active is not None else 0
        if paused:
            self.interruption_summary = self.media.active.summary if self.media.active else None
        if state == self.lock:
            if paused and notify:
                self.changed()
            return
        lifted = self.lock.active is not None and state.active is None
        if state.active != self.lock.active:
            log.info("prayer lock %s", f"on for {state.active.kind}" if state.active else "off")
        self.lock = state
        if lifted and self._resume_deferred:
            self._resume_deferred = False
            self.media.resume()
            self.interruption_summary = None
        if notify:
            self.changed()

    @property
    def current_window(self) -> Optional[PrayerWindow]:
        return tracker.window_at(time.time(), self.settings, self.scheduler.engine)

    def status_of(self, window: PrayerWindow) -> str:
        return tracker.status(self.prayer_log.log, window, time.time())

    def confirm_prayed(self, window: PrayerWindow) -> None:
        """The oath. Inside the window it is on time; after it, qada."""
        self.prayer_log.record(window.day, window.kind, tracker.status_for_record(window, time.time()))
        self.check_lock(notify=False)
        self.changed()

    def set_status(self, day: str, prayer: str, status: Optional[str]) -> None:
        """Correct the record from the tracker: qada, excused, or cleared."""
        if status is None:
            self.prayer_log.clear(day, prayer)
        else:
            self.prayer_log.record(day, prayer, status)
        self.check_lock(notify=False)
        self.changed()

    def history(self, days: int) -> list:
        return tracker.history(self.prayer_log.log, self.settings, time.time(), days, self.scheduler.engine)

    # MARK: - Display state

    @property
    def next_prayer(self) -> Optional[ScheduledPrayer]:
        return self.scheduler.next_prayer

    @property
    def current_prayer(self) -> Optional[ScheduledPrayer]:
        today = self.scheduler.today
        return today.current_prayer(time.time()) if today else None
