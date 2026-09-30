"""The visual side of Barakah's alerts — NotificationService.swift for Linux.

On macOS every notification is pre-scheduled with the system, so an iqama
reminder arrives even if Barakah was quit, crashed, or the machine only just
woke. Linux notification servers have no scheduling, so the equivalent here is
a transient systemd user timer per notification (`systemd-run --user
--on-calendar=…`) that runs `notify-send` when it comes due. Those timers
belong to the user's systemd instance, not to Barakah, so they survive the app
quitting or crashing just as the Mac's do.

Where there is no systemd user instance, notifications fall back to being
posted live by the running app, and the settings window says so.
"""

from __future__ import annotations

import logging
import shutil
import subprocess
import threading
from datetime import datetime, timezone
from typing import Callable, Optional

from . import APP_ID, DISPLAY_NAME, paths
from .engine import PrayerEvent, PrayerTimeEngine, place_zone
from .formatting import PrayerFormatter
from .model import ARABIC_NAMES, NAMES, SettingsData

log = logging.getLogger("barakah.notify")

HORIZON_DAYS = 3
PENDING_LIMIT = 60
UNIT_PREFIX = "barakah-notify-"


def content(event: PrayerEvent, settings: SettingsData, fmt: PrayerFormatter) -> Optional[tuple[str, str]]:
    """Title and body for an event, or None when it should stay silent."""
    name = NAMES[event.prayer]
    if event.kind == "athan":
        if not settings.notify_at_athan:
            return None
        title = f"{name} — {fmt.time(event.fire_at)}"
        if settings.config(event.prayer).iqama_rule.is_enabled:
            return title, f"It is time for {name}."
        return title, f"It is time for {name}. {ARABIC_NAMES[event.prayer]}"
    if event.kind == "iqamaReminder":
        minutes = event.minutes_before
        return f"{name} iqama in {minutes} min", f"Iqama at {fmt.time(event.fire_at + minutes * 60)}."
    return f"{name} iqama", "The iqama has been called."


def notify_send_args(title: str, body: str, sound: bool) -> list[str]:
    args = ["notify-send", f"--app-name={DISPLAY_NAME}", f"--icon={paths.app_icon()}",
            f"--hint=string:desktop-entry:{APP_ID}", "--category=x-barakah.prayer"]
    if sound:
        args.append("--hint=string:sound-name:message-new-instant")
    else:
        args.append("--hint=boolean:suppress-sound:true")
    return args + ["--", title, body]


class NotificationService:
    def __init__(self):
        self.prescheduled = bool(shutil.which("systemd-run") and shutil.which("systemctl")
                                 and shutil.which("notify-send") and self._user_manager_running())
        self._lock = threading.Lock()
        self._generation = 0

    @staticmethod
    def _user_manager_running() -> bool:
        try:
            result = subprocess.run(["systemctl", "--user", "is-system-running"],
                                    capture_output=True, text=True, timeout=5)
        except (OSError, subprocess.TimeoutExpired):
            return False
        return result.stdout.strip() in ("running", "degraded", "starting")

    # MARK: - Pre-scheduled (systemd timers)

    def reschedule(self, settings: SettingsData, now: float,
                   is_suppressed: Callable[[str, float], bool] = lambda _p, _t: False) -> None:
        """Replace every pending notification with those implied by `settings`.

        Runs off the main loop: it forks a process per notification. Only the
        newest request survives — each begins by removing everything pending,
        so two interleaving could leave an older run's timers behind."""
        if not self.prescheduled:
            return
        # Bumped on the main thread without waiting for a worker: any worker
        # still running sees it and stops adding timers from a stale plan.
        self._generation += 1
        generation = self._generation
        events = PrayerTimeEngine().events(now, HORIZON_DAYS * 86_400, settings)
        fmt = PrayerFormatter(settings.use_24_hour_clock, settings.active_place)
        tz = place_zone(settings.active_place)
        planned = []
        for event in events:
            if len(planned) >= PENDING_LIMIT:
                break
            if is_suppressed(event.prayer, event.fire_at):
                continue
            text = content(event, settings, fmt)
            if text is None:
                continue
            planned.append((event.key(tz), event.fire_at, text))
        threading.Thread(target=self._apply, args=(generation, planned, settings.notification_sound_enabled),
                         daemon=True, name="barakah-notify").start()

    def _apply(self, generation: int, planned, sound: bool) -> None:
        with self._lock:
            if generation != self._generation:
                return
            self._cancel_locked()
            scheduled = 0
            for key, fire_at, (title, body) in planned:
                if generation != self._generation:
                    return
                when = datetime.fromtimestamp(fire_at, timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC")
                cmd = ["systemd-run", "--user", "--quiet", "--collect",
                       f"--unit={UNIT_PREFIX}{key}",
                       f"--description={DISPLAY_NAME}: {title}",
                       f"--on-calendar={when}",
                       "--timer-property=AccuracySec=1s",
                       "--timer-property=RemainAfterElapse=no",
                       "--", *notify_send_args(title, body, sound)]
                try:
                    result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
                except (OSError, subprocess.TimeoutExpired) as error:
                    log.error("failed to schedule %s: %s", key, error)
                    continue
                if result.returncode == 0:
                    scheduled += 1
                else:
                    log.error("failed to schedule %s: %s", key, result.stderr.strip())
            log.info("scheduled %d notifications over %d days", scheduled, HORIZON_DAYS)

    def _cancel_locked(self) -> None:
        try:
            subprocess.run(["systemctl", "--user", "stop", f"{UNIT_PREFIX}*.timer"],
                           capture_output=True, timeout=15)
        except (OSError, subprocess.TimeoutExpired) as error:
            log.error("failed to clear pending notifications: %s", error)

    def cancel_all(self) -> None:
        if not self.prescheduled:
            return
        self._generation += 1
        with self._lock:
            self._cancel_locked()

    def pending(self) -> list[str]:
        try:
            result = subprocess.run(
                ["systemctl", "--user", "list-timers", "--all", "--no-legend", "--plain", f"{UNIT_PREFIX}*"],
                capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            return []
        return [line for line in result.stdout.splitlines() if line.strip()]

    # MARK: - Live fallback

    def post_now(self, event: PrayerEvent, settings: SettingsData) -> None:
        """Only used when timers are unavailable: the running app posts the
        notification itself as the event fires."""
        if self.prescheduled:
            return
        text = content(event, settings, PrayerFormatter(settings.use_24_hour_clock, settings.active_place))
        if text is None:
            return
        try:
            subprocess.Popen(notify_send_args(*text, settings.notification_sound_enabled),
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as error:
            log.error("notify-send failed: %s", error)
