"""The tray icon, its menu, and the floating athan panel — MenuBarController,
PopoverView and AthanWindow from the macOS app, on AyatanaAppIndicator.

A GNOME tray icon cannot take a bare click (the shell always opens its menu),
so the menu *is* the day view: the next prayer with its countdown, the day's
times with their iqamas, and — while the athan sounds — "Stop athan" as the
very first item, so stopping it is still a single click after opening the menu.
The floating panel puts a Stop button on screen without even that.
"""

from __future__ import annotations

import math
import time
from typing import Callable, Optional

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("AyatanaAppIndicator3", "0.1")
from gi.repository import AyatanaAppIndicator3 as AppIndicator  # noqa: E402
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

from . import APP_ID, DISPLAY_NAME, paths  # noqa: E402
from . import tracker  # noqa: E402
from .formatting import PrayerFormatter  # noqa: E402
from .model import ARABIC_NAMES, NAMES, is_prayer  # noqa: E402

# How a recorded prayer reads at the end of its row.
STATUS_MARKS = {
    tracker.PRAYED: "✓ prayed", tracker.QADA: "✓ made up", tracker.EXCUSED: "excused",
    tracker.MISSED: "missed",
}

ACCENTS = {
    "fajr": (0.36, 0.40, 0.72), "sunrise": (0.90, 0.58, 0.36), "dhuhr": (0.24, 0.60, 0.82),
    "asr": (0.82, 0.62, 0.28), "maghrib": (0.84, 0.42, 0.36), "isha": (0.30, 0.34, 0.58),
}


def _item(label: str, action: Optional[Callable[[], None]] = None, sensitive: bool = True) -> Gtk.MenuItem:
    item = Gtk.MenuItem(label=label)
    if action is not None:
        item.connect("activate", lambda *_: action())
    item.set_sensitive(sensitive and action is not None)
    return item


class Tray:
    def __init__(self, app, open_settings: Callable[[], None], quit_app: Callable[[], None],
                 open_tracker: Callable[[], None]):
        self.app = app
        self.open_settings = open_settings
        self.quit_app = quit_app
        self.open_tracker = open_tracker
        self.indicator = AppIndicator.Indicator.new(
            APP_ID, "barakah-tray-symbolic", AppIndicator.IndicatorCategory.APPLICATION_STATUS)
        self.indicator.set_icon_theme_path(paths.icons_dir())
        self.indicator.set_title(DISPLAY_NAME)
        self.indicator.set_status(AppIndicator.IndicatorStatus.ACTIVE)
        self.menu = Gtk.Menu()
        self.indicator.set_menu(self.menu)
        self._structure = None
        self._labels: dict[str, Gtk.MenuItem] = {}
        self._window = None
        self._statuses: dict[str, str] = {}
        self.athan_window: Optional[AthanWindow] = None
        app.subscribe(self.refresh)
        # Five seconds keeps a minute-resolution countdown honest at the
        # boundary without waking the CPU more than necessary.
        GLib.timeout_add_seconds(5, lambda: (self.refresh(), True)[1])
        self.refresh()

    @property
    def fmt(self) -> PrayerFormatter:
        s = self.app.settings
        return PrayerFormatter(s.use_24_hour_clock, s.active_place)

    # MARK: - Label and icon

    def _label(self) -> str:
        nxt = self.app.next_prayer
        if nxt is None:
            return "—"
        style = self.app.settings.menu_bar_style
        name = NAMES[nxt.kind]
        if style == "countdown":
            return f"{name} in {PrayerFormatter.countdown(nxt.athan - time.time())}"
        if style == "nextTime":
            return f"{name} {self.fmt.time(nxt.athan)}"
        if style == "nextName":
            return name
        return ""

    def refresh(self) -> None:
        playing = self.app.audio.is_playing
        if playing:
            icon = "barakah-tray-playing-symbolic"
        elif self.app.is_globally_muted:
            icon = "barakah-tray-muted-symbolic"
        else:
            icon = "barakah-tray-symbolic"
        self.indicator.set_icon_full(icon, DISPLAY_NAME)
        label = "Stop athan" if playing else self._label()
        self.indicator.set_label(label, "Maghrib 12:59 PM")
        self._refresh_menu()
        self._sync_athan_window(playing)

    # MARK: - Menu

    def _refresh_menu(self) -> None:
        app = self.app
        today = app.scheduler.today
        prayers = tuple(today.prayers) if today else ()
        window = app.current_window
        # Offer the oath for the prayer whose time it is, until it is recorded.
        recorded = window is not None and app.prayer_log.log.entry(window.day, window.kind) is not None
        self._window = window if window is not None and not recorded else None
        records = app.history(1)
        self._statuses = records[0].statuses if records else {}
        structure = (
            self._window, app.settings.lock.enabled,
            app.audio.is_playing, app.media.active is not None, app.is_globally_muted,
            today.day if today else None, tuple(p.kind for p in prayers),
            tuple(app.is_muted_today(p.kind) for p in prayers),
            app.settings.show_hijri_date, app.settings.active_place,
        )
        if structure != self._structure:
            self._structure = structure
            self._build_menu(prayers)
        self._update_labels(prayers)

    def _build_menu(self, prayers) -> None:
        for child in self.menu.get_children():
            self.menu.remove(child)
        self._labels = {}
        app = self.app
        add = self.menu.append

        if app.audio.is_playing:
            add(_item("■  Stop athan", app.stop_athan))
            add(Gtk.SeparatorMenuItem())
        self._labels["headline"] = _item("", sensitive=False)
        self._labels["detail"] = _item("", sensitive=False)
        add(self._labels["headline"])
        add(self._labels["detail"])
        if app.media.active is not None:
            self._labels["summary"] = _item("", sensitive=False)
            add(self._labels["summary"])
            add(_item("Resume paused media", app.resume_media_now))
        if self._window is not None:
            window = self._window
            add(Gtk.SeparatorMenuItem())
            self._labels["oath"] = _item("", lambda: app.confirm_prayed(window))
            add(self._labels["oath"])
        add(Gtk.SeparatorMenuItem())

        for prayer in prayers:
            kind = prayer.kind
            action = (lambda k=kind: app.toggle_mute_today(k)) if is_prayer(kind) else None
            item = _item("", action)
            self._labels[f"row-{kind}"] = item
            add(item)
        if not prayers:
            add(_item("No times available — set a location in Settings", self.open_settings))
        add(Gtk.SeparatorMenuItem())

        self._labels["place"] = _item("", sensitive=False)
        self._labels["date"] = _item("", sensitive=False)
        add(self._labels["place"])
        add(self._labels["date"])
        add(Gtk.SeparatorMenuItem())

        if app.is_globally_muted:
            self._labels["muted"] = _item("", lambda: app.mute(None))
            add(self._labels["muted"])
        else:
            silence = Gtk.MenuItem(label="Silence athans")
            sub = Gtk.Menu()
            sub.append(_item("For 15 minutes", lambda: app.mute(15 * 60)))
            sub.append(_item("For 1 hour", lambda: app.mute(3600)))
            sub.append(_item("Until tomorrow", lambda: app.mute(app.seconds_until_tomorrow())))
            silence.set_submenu(sub)
            add(silence)
        add(_item("Prayer tracker…", self.open_tracker))
        add(_item("Settings…", self.open_settings))
        add(_item("Quit Barakah", self.quit_app))
        self.menu.show_all()

    def _update_labels(self, prayers) -> None:
        app, fmt, now = self.app, self.fmt, time.time()
        labels = self._labels

        def put(key: str, text: str) -> None:
            item = labels.get(key)
            if item is not None and item.get_label() != text:
                item.set_label(text)

        nxt = app.next_prayer
        if app.audio.is_playing and app.audio.playing_prayer:
            kind = app.audio.playing_prayer
            put("headline", f"{NAMES[kind]} — athan  {ARABIC_NAMES[kind]}")
            put("detail", f"{int(app.audio.progress * 100)}% played")
        elif nxt is not None:
            put("headline", f"{NAMES[nxt.kind]}  {ARABIC_NAMES[nxt.kind]}  ·  {fmt.long_countdown(nxt.athan - now)}")
            detail = fmt.time(nxt.athan)
            if nxt.iqama is not None:
                detail += f"  ·  iqama {fmt.time(nxt.iqama)}"
            put("detail", detail)
        else:
            put("headline", "No times available")
            put("detail", "Set a location in Settings")
        if app.interruption_summary:
            put("summary", app.interruption_summary)

        # Menu text cannot be laid out in columns, so a row's state is words
        # at its end rather than a marker that would push its times sideways.
        current = app.current_prayer
        for prayer in prayers:
            text = f"{NAMES[prayer.kind]}   {fmt.time(prayer.athan)}"
            if prayer.iqama is not None:
                text += f"  ·  iqama {fmt.time(prayer.iqama)}"
            if nxt is not None and prayer.kind == nxt.kind and prayer.athan > now:
                text += "   — next"
            elif current is not None and prayer.kind == current.kind:
                text += "   — now"
            if is_prayer(prayer.kind) and app.is_muted_today(prayer.kind):
                text += "   (athan off today)"
            mark = STATUS_MARKS.get(self._statuses.get(prayer.kind, ""))
            if mark:
                text += f"   {mark}"
            put(f"row-{prayer.kind}", text)

        if self._window is not None:
            oath = f"I prayed {NAMES[self._window.kind]}"
            lock = app.lock
            if lock.next_window == self._window and lock.next_at is not None:
                oath += f"   (screen locks at {fmt.time(lock.next_at)})"
            put("oath", oath)

        put("place", app.settings.active_place.name)
        date = fmt.gregorian_date(now)
        if app.settings.show_hijri_date:
            hijri = fmt.hijri_date(now)
            if hijri:
                date += f"  ·  {hijri}"
        put("date", date)
        if app.muted_until:
            put("muted", f"Athans silenced until {fmt.time(app.muted_until)} — turn back on")

    # MARK: - Athan window

    def _sync_athan_window(self, playing: bool) -> None:
        if playing and self.app.settings.show_athan_window and self.app.audio.playing_prayer:
            if self.athan_window is None:
                self.athan_window = AthanWindow(self.app)
            self.athan_window.present_panel()
        elif self.athan_window is not None:
            self.athan_window.destroy()
            self.athan_window = None


class AthanWindow(Gtk.Window):
    """A small floating panel while the athan sounds: what is playing, what
    was paused, and Stop. It never takes focus and leaves when playback ends."""

    def __init__(self, app):
        super().__init__(title=f"{DISPLAY_NAME} — Athan")
        self.app = app
        self.set_decorated(False)
        self.set_keep_above(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_accept_focus(False)
        self.set_focus_on_map(False)
        self.set_type_hint(Gdk.WindowTypeHint.UTILITY)
        self.stick()
        self.set_resizable(False)
        self.set_default_size(320, -1)

        frame = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=13)
        frame.set_border_width(14)
        self.ring = Gtk.DrawingArea()
        self.ring.set_size_request(46, 46)
        self.ring.connect("draw", self._draw_ring)
        frame.pack_start(self.ring, False, False, 0)

        text = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=3)
        self.title_label = Gtk.Label(xalign=0)
        self.subtitle = Gtk.Label(xalign=0)
        self.subtitle.get_style_context().add_class("dim-label")
        text.pack_start(self.title_label, False, False, 0)
        text.pack_start(self.subtitle, False, False, 0)
        frame.pack_start(text, True, True, 0)

        buttons = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=4)
        stop = Gtk.Button(label="Stop")
        stop.get_style_context().add_class("suggested-action")
        stop.set_tooltip_text("Stop the athan")
        stop.connect("clicked", lambda *_: app.stop_athan())
        buttons.pack_start(stop, False, False, 0)
        self.resume = Gtk.Button(label="Resume media")
        self.resume.connect("clicked", lambda *_: app.resume_media_now())
        buttons.pack_start(self.resume, False, False, 0)
        frame.pack_end(buttons, False, False, 0)
        self.add(frame)

        self._tick = GLib.timeout_add(250, self._on_tick)
        self.connect("destroy", lambda *_: GLib.source_remove(self._tick))
        self._on_tick()

    def present_panel(self) -> None:
        if not self.get_visible():
            self.show_all()
            self._position()
        self.resume.set_visible(self.app.media.active is not None)

    def _position(self) -> None:
        # Top right of the primary monitor, under the panel where the tray icon sits.
        display = Gdk.Display.get_default()
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        area = monitor.get_workarea()
        width, _height = self.get_size()
        self.move(area.x + area.width - width - 12, area.y + 12)

    def _on_tick(self) -> bool:
        kind = self.app.audio.playing_prayer
        name = NAMES.get(kind, "Athan")
        arabic = ARABIC_NAMES.get(kind, "")
        self.title_label.set_markup(f"<b><big>{GLib.markup_escape_text(name)}</big></b>  "
                                    f"<span alpha='60%'>{GLib.markup_escape_text(arabic)}</span>")
        self.subtitle.set_text(self.app.interruption_summary or "It is time for prayer")
        self.resume.set_visible(self.app.media.active is not None)
        self.ring.queue_draw()
        return True

    def _draw_ring(self, widget, cr) -> None:
        w, h = widget.get_allocated_width(), widget.get_allocated_height()
        r, g, b = ACCENTS.get(self.app.audio.playing_prayer, (0.36, 0.40, 0.72))
        cx, cy, radius = w / 2, h / 2, min(w, h) / 2 - 3
        cr.set_source_rgba(r, g, b, 0.10)
        cr.arc(cx, cy, radius, 0, 2 * math.pi)
        cr.fill()
        cr.set_line_width(4)
        cr.set_source_rgba(r, g, b, 0.22)
        cr.arc(cx, cy, radius, 0, 2 * math.pi)
        cr.stroke()
        progress = max(0.004, min(1.0, self.app.audio.progress))
        cr.set_source_rgb(r, g, b)
        cr.set_line_cap(1)  # round
        cr.arc(cx, cy, radius, -math.pi / 2, -math.pi / 2 + progress * 2 * math.pi)
        cr.stroke()
        # The speaker, drawn small in the middle.
        cr.move_to(cx - 7, cy - 3)
        cr.line_to(cx - 3, cy - 3)
        cr.line_to(cx + 2, cy - 8)
        cr.line_to(cx + 2, cy + 8)
        cr.line_to(cx - 3, cy + 3)
        cr.line_to(cx - 7, cy + 3)
        cr.close_path()
        cr.fill()
        cr.set_line_width(2)
        cr.arc(cx + 3, cy, 6, -math.pi / 4, math.pi / 4)
        cr.stroke()
