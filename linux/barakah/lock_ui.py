"""The prayer lock: a cover over every monitor that only "Wallahi, I prayed
<prayer>" lifts — LockOverlay.swift on the Mac.

On X11 one client may take the whole keyboard and pointer, so each monitor
gets an override-redirect window (the window manager cannot move, minimise or
stack anything above it) and the cover holds a seat grab: Alt+Tab, Super,
Ctrl+Alt+Del and every other shortcut arrive here and go nowhere. Mutter
treats a monitor-sized override-redirect window as fullscreen, so the top bar
steps aside too. Wayland gives no client that power; there the cover is a
fullscreen keep-above window and the shell's own shortcuts still work.

What the cover shows is derived, not remembered: AppState re-derives the lock
every few seconds and the cover follows it, so it leaves by itself when the
prayer's time ends.
"""

from __future__ import annotations

import logging
import time
from typing import Callable, Optional

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gdk, GLib, GObject, Gtk  # noqa: E402

from .formatting import PrayerFormatter  # noqa: E402
from .model import ARABIC_NAMES, NAMES  # noqa: E402
from .tracker import PrayerWindow  # noqa: E402
from .tray import ACCENTS  # noqa: E402

log = logging.getLogger("barakah.lock")

ENDS_AT = {"fajr": "Sunrise", "dhuhr": "Asr", "asr": "Maghrib", "maghrib": "Isha", "isha": "Fajr"}

VERSE = "إِنَّ الصَّلَاةَ كَانَتْ عَلَى الْمُؤْمِنِينَ كِتَابًا مَّوْقُوتًا"
VERSE_MEANING = "Indeed, prayer has been decreed upon the believers at fixed times.  — An-Nisa 4:103"

BACKDROP = (0.043, 0.055, 0.090)


def _hex(rgb: tuple) -> str:
    return "#" + "".join(f"{max(0, min(255, round(c * 255))):02x}" for c in rgb)


def _mix(a: tuple, b: tuple, t: float) -> tuple:
    return tuple(x * (1 - t) + y * t for x, y in zip(a, b))


def _css(accent: tuple) -> bytes:
    top = _hex(_mix(BACKDROP, accent, 0.30))
    base = _hex(BACKDROP)
    button = _hex(_mix(accent, (1, 1, 1), 0.08))
    hover = _hex(_mix(accent, (1, 1, 1), 0.22))
    return f"""
    window.barakah-lock {{
        background-color: {base};
        background-image: linear-gradient(to bottom, {top}, {base} 70%);
    }}
    .barakah-lock label {{ color: rgba(255, 255, 255, 0.94); }}
    .barakah-lock .arabic {{ font-size: 92px; }}
    .barakah-lock .name {{ font-size: 30px; font-weight: 600; letter-spacing: 1px; }}
    .barakah-lock .detail {{ font-size: 15px; color: rgba(255, 255, 255, 0.62); }}
    .barakah-lock .remaining {{ font-size: 15px; color: rgba(255, 255, 255, 0.82); }}
    .barakah-lock .verse {{ font-size: 22px; color: rgba(255, 255, 255, 0.74); }}
    .barakah-lock .meaning {{ font-size: 13px; color: rgba(255, 255, 255, 0.46); }}
    .barakah-lock .secondary {{ font-size: 20px; color: rgba(255, 255, 255, 0.40); }}
    .barakah-lock button.oath {{
        font-size: 21px; font-weight: 600; color: #ffffff;
        padding: 16px 44px; border-radius: 999px; border: none; box-shadow: none;
        background-image: none; background-color: {button};
    }}
    .barakah-lock button.oath:hover {{ background-color: {hover}; }}
    .barakah-lock button.oath label {{ color: #ffffff; }}
    .barakah-lock button.quiet {{
        font-size: 13px; padding: 6px 16px; border-radius: 999px; box-shadow: none;
        background-image: none; background-color: rgba(255, 255, 255, 0.08);
        border: 1px solid rgba(255, 255, 255, 0.14);
    }}
    .barakah-lock button.quiet label {{ color: rgba(255, 255, 255, 0.78); }}
    """.encode("utf-8")


def _label(text: str, *classes: str) -> Gtk.Label:
    label = Gtk.Label(label=text, justify=Gtk.Justification.CENTER, wrap=True)
    for name in classes:
        label.get_style_context().add_class(name)
    return label


def _is_x11(display: Gdk.Display) -> bool:
    return GObject.type_name(display.__gtype__) == "GdkX11Display"


class LockOverlay:
    """Follows `app.lock.active`: call `sync()` whenever the app changes.

    `preview` shows the cover for a window without recording anything — its
    button only closes it — and lifts by itself after `preview_seconds`."""

    def __init__(self, app, preview: bool = False, preview_seconds: int = 60,
                 on_close: Optional[Callable[[], None]] = None):
        self.app = app
        self.preview = preview
        self.on_close = on_close
        self.window: Optional[PrayerWindow] = None
        self._covers: list[Gtk.Window] = []
        self._primary: Optional[Gtk.Window] = None
        self._labels: dict[str, Gtk.Label] = {}
        self._stop: Optional[Gtk.Button] = None
        self._provider = Gtk.CssProvider()
        self._grabbed = False
        self._tick = 0
        self._preview_seconds = preview_seconds
        self._preview_deadline: Optional[float] = None
        display = Gdk.Display.get_default()
        self._x11 = _is_x11(display)
        display.connect("monitor-added", lambda *_: self._rebuild())
        display.connect("monitor-removed", lambda *_: self._rebuild())

    @property
    def is_shown(self) -> bool:
        return self.window is not None

    def sync(self) -> None:
        if self.preview:
            return
        active = self.app.lock.active
        if active is None:
            self.hide()
        elif active != self.window:
            self.show(active)

    def show(self, window: PrayerWindow) -> None:
        self.window = window
        if self.preview:
            self._preview_deadline = time.time() + self._preview_seconds
        self._provider.load_from_data(_css(ACCENTS.get(window.kind, ACCENTS["isha"])))
        Gtk.StyleContext.add_provider_for_screen(
            Gdk.Screen.get_default(), self._provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION + 1)
        self._rebuild()
        if not self._tick:
            self._tick = GLib.timeout_add(1000, self._on_tick)
        self._on_tick()

    def hide(self) -> None:
        if self.window is None:
            return
        self.window = None
        if self._tick:
            GLib.source_remove(self._tick)
            self._tick = 0
        self._release()
        self._destroy_covers()
        Gtk.StyleContext.remove_provider_for_screen(Gdk.Screen.get_default(), self._provider)
        if self.on_close is not None:
            self.on_close()

    # MARK: - Covers

    def _destroy_covers(self) -> None:
        for cover in self._covers:
            cover.destroy()
        self._covers = []
        self._primary = None
        self._labels = {}
        self._stop = None

    def _rebuild(self) -> None:
        if self.window is None:
            return
        self._release()
        self._destroy_covers()
        display = Gdk.Display.get_default()
        primary = display.get_primary_monitor() or display.get_monitor(0)
        for index in range(display.get_n_monitors()):
            monitor = display.get_monitor(index)
            cover = self._cover(monitor, monitor == primary)
            self._covers.append(cover)
            if monitor == primary:
                self._primary = cover
        # Grab once the cover is on screen; a grab on an unmapped window fails.
        GLib.idle_add(lambda: (self._grab(), False)[1])

    def _cover(self, monitor: Gdk.Monitor, primary: bool) -> Gtk.Window:
        kind = Gtk.WindowType.POPUP if self._x11 else Gtk.WindowType.TOPLEVEL
        cover = Gtk.Window(type=kind)
        cover.set_title("Barakah — prayer time")
        cover.get_style_context().add_class("barakah-lock")
        cover.set_app_paintable(False)
        cover.set_decorated(False)
        cover.set_skip_taskbar_hint(True)
        cover.set_skip_pager_hint(True)
        cover.set_keep_above(True)
        geometry = monitor.get_geometry()
        cover.move(geometry.x, geometry.y)
        cover.set_default_size(geometry.width, geometry.height)
        cover.set_size_request(geometry.width, geometry.height)
        # Closing it the window manager's way does nothing: only the oath does.
        cover.connect("delete-event", lambda *_: True)
        cover.add(self._content(primary))
        cover.show_all()
        if self._stop is not None and primary:
            self._stop.set_visible(self.app.audio.is_playing)
        if not self._x11:
            cover.fullscreen_on_monitor(cover.get_screen(), self._monitor_index(monitor))
        return cover

    @staticmethod
    def _monitor_index(monitor: Gdk.Monitor) -> int:
        display = monitor.get_display()
        return next((i for i in range(display.get_n_monitors()) if display.get_monitor(i) == monitor), 0)

    def _content(self, primary: bool) -> Gtk.Widget:
        window = self.window
        name, arabic = NAMES[window.kind], ARABIC_NAMES[window.kind]
        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        box.set_halign(Gtk.Align.CENTER)
        box.set_valign(Gtk.Align.CENTER)
        if not primary:
            box.pack_start(_label(arabic, "secondary"), False, False, 0)
            return box

        box.pack_start(_label(arabic, "arabic"), False, False, 0)
        box.pack_start(_label(name, "name"), False, False, 0)
        self._labels["detail"] = _label("", "detail")
        self._labels["detail"].set_margin_top(10)
        box.pack_start(self._labels["detail"], False, False, 0)
        self._labels["remaining"] = _label("", "remaining")
        box.pack_start(self._labels["remaining"], False, False, 0)

        oath = Gtk.Button(label=f"Wallahi, I prayed {name}")
        oath.get_style_context().add_class("oath")
        oath.set_halign(Gtk.Align.CENTER)
        oath.set_margin_top(34)
        oath.set_can_focus(False)
        oath.connect("clicked", lambda *_: self._swear())
        box.pack_start(oath, False, False, 0)

        self._stop = Gtk.Button(label="Stop athan")
        self._stop.get_style_context().add_class("quiet")
        self._stop.set_halign(Gtk.Align.CENTER)
        self._stop.set_margin_top(14)
        self._stop.set_can_focus(False)
        self._stop.set_no_show_all(True)
        self._stop.connect("clicked", lambda *_: self.app.stop_athan())
        box.pack_start(self._stop, False, False, 0)

        verse = _label(VERSE, "verse")
        verse.set_margin_top(56)
        box.pack_start(verse, False, False, 0)
        box.pack_start(_label(VERSE_MEANING, "meaning"), False, False, 0)
        if self.preview:
            note = _label("Preview — nothing is recorded, and this closes by itself.", "meaning")
            note.set_margin_top(18)
            box.pack_start(note, False, False, 0)
        return box

    def _swear(self) -> None:
        window = self.window
        if window is None:
            return
        if self.preview:
            self.hide()
            return
        log.info("sworn: %s %s", window.kind, window.day)
        self.app.confirm_prayed(window)
        # AppState notifies, and sync() takes the cover down; make sure of it
        # even if this window was not the one the lock was holding.
        if self.app.lock.active is None:
            self.hide()

    # MARK: - Grab

    def _grab(self) -> None:
        if not self._x11 or self._grabbed or self._primary is None:
            return
        gdk_window = self._primary.get_window()
        if gdk_window is None or not gdk_window.is_viewable():
            return
        seat = Gdk.Display.get_default().get_default_seat()
        # owner_events: the covers on other monitors are ours and get their
        # own events; everything else is reported to the primary cover.
        status = seat.grab(gdk_window, Gdk.SeatCapabilities.ALL, True, None, None, None, None)
        self._grabbed = status == Gdk.GrabStatus.SUCCESS
        if not self._grabbed:
            # The shell holds a grab while its own menus are open; try again.
            log.debug("grab refused (%s); retrying", status.value_nick)

    def _release(self) -> None:
        if self._grabbed:
            Gdk.Display.get_default().get_default_seat().ungrab()
            self._grabbed = False

    # MARK: - Tick

    def _on_tick(self) -> bool:
        if self.window is None:
            self._tick = 0
            return False
        try:
            now = time.time()
            if self._preview_deadline is not None and now >= self._preview_deadline:
                self.hide()
                return False
            for cover in self._covers:
                gdk_window = cover.get_window()
                if gdk_window is not None:
                    gdk_window.raise_()
            self._grab()
            self._update_text(now)
        except Exception:  # a broken tick must not strand a grabbed screen
            log.exception("lock tick failed")
        return True

    def _update_text(self, now: float) -> None:
        window, labels = self.window, self._labels
        if window is None or "detail" not in labels:
            return
        s = self.app.settings
        fmt = PrayerFormatter(s.use_24_hour_clock, s.active_place)
        detail = f"Began at {fmt.time(window.start)}"
        if window.iqama is not None:
            detail += f"  ·  iqama {fmt.time(window.iqama)}"
        labels["detail"].set_text(detail)
        left = PrayerFormatter.countdown(window.end - now)
        labels["remaining"].set_text(f"Its time ends at {ENDS_AT[window.kind]}, {fmt.time(window.end)} — {left} left")
        if self._stop is not None:
            self._stop.set_visible(self.app.audio.is_playing)
