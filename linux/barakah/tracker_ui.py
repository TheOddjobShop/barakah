"""The prayer tracker window — TrackerView.swift on the Mac.

A year of prayer as GitHub draws a year of contributions: one square a day,
as green as it was kept. Above it the streaks and how much was prayed on time;
below it the day picked on the heatmap (today, to begin with), whose five
prayers can each be corrected — prayed at the masjid with the laptop shut,
made up later, or not owed — because the oath was the user's word in the
first place.
"""

from __future__ import annotations

import math
from datetime import date as _date
from typing import Optional

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

from . import APP_ID, tracker  # noqa: E402
from .engine import make_instant, place_zone  # noqa: E402
from .formatting import PrayerFormatter  # noqa: E402
from .heatmap import DAYS as YEAR, Heatmap, describe, year_footer  # noqa: E402
from .model import NAMES, PRAYERS  # noqa: E402

DAYS = 30

COLOURS = {
    tracker.PRAYED: (0.25, 0.70, 0.50),
    tracker.QADA: (0.88, 0.64, 0.23),
    tracker.EXCUSED: (0.49, 0.56, 0.70),
    tracker.MISSED: (0.88, 0.36, 0.36),
}
LABELS = {
    tracker.PRAYED: "Prayed on time", tracker.QADA: "Made up (qada)", tracker.EXCUSED: "Excused",
    tracker.MISSED: "Missed", tracker.OPEN: "Its time is now", tracker.UPCOMING: "Not yet",
    tracker.UNTRACKED: "Before tracking began",
}

CSS = b"""
.tracker-streak { font-size: 40px; font-weight: 700; }
.tracker-caption { font-size: 12px; opacity: 0.65; }
.tracker-figure { font-size: 22px; font-weight: 600; }
.tracker-title { font-size: 15px; font-weight: 600; }
.tracker-heading { font-size: 12px; font-weight: 600; opacity: 0.7; }
.tracker-card { border: 1px solid alpha(currentColor, 0.15); border-radius: 8px; padding: 14px 16px 6px 16px; }
"""


def _label(text: str, *classes: str, xalign: float = 0.5) -> Gtk.Label:
    label = Gtk.Label(label=text, xalign=xalign)
    for name in classes:
        label.get_style_context().add_class(name)
    return label


class Dot(Gtk.EventBox):
    """One prayer on one day: filled when recorded or missed, a ring while its
    time is now, faint before then."""

    SIZE = 22

    def __init__(self, status: str, accent=(0.30, 0.34, 0.58)):
        super().__init__()
        self.status = status
        self.accent = accent
        area = Gtk.DrawingArea()
        area.set_size_request(self.SIZE, self.SIZE)
        area.connect("draw", self._draw)
        self.add(area)
        self.set_tooltip_text(LABELS.get(status, status))

    def _draw(self, widget, cr) -> None:
        w, h = widget.get_allocated_width(), widget.get_allocated_height()
        cx, cy, r = w / 2, h / 2, min(w, h) / 2 - 3
        colour = COLOURS.get(self.status)
        if colour is not None:
            cr.set_source_rgb(*colour)
            cr.arc(cx, cy, r, 0, 2 * math.pi)
            cr.fill()
            if self.status in (tracker.PRAYED, tracker.QADA):
                cr.set_source_rgb(1, 1, 1)
                cr.set_line_width(2)
                cr.move_to(cx - r * 0.45, cy + r * 0.02)
                cr.line_to(cx - r * 0.1, cy + r * 0.38)
                cr.line_to(cx + r * 0.5, cy - r * 0.35)
                cr.stroke()
        elif self.status == tracker.OPEN:
            cr.set_source_rgb(*self.accent)
            cr.set_line_width(2.5)
            cr.arc(cx, cy, r - 1, 0, 2 * math.pi)
            cr.stroke()
        else:
            cr.set_source_rgba(0.5, 0.5, 0.5, 0.22)
            cr.arc(cx, cy, r * 0.55, 0, 2 * math.pi)
            cr.fill()


class TrackerWindow(Gtk.Window):
    def __init__(self, app):
        super().__init__(title="Prayer Tracker")
        self.app = app
        self.set_icon_name(APP_ID)
        self.set_default_size(880, 560)
        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), provider,
                                                 Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)
        self._records: Optional[list] = None
        self._selected: Optional[str] = None
        self._menu: Optional[Gtk.Menu] = None

        outer = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        self._summary_box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=28)
        self._summary_box.set_border_width(20)
        outer.pack_start(self._summary_box, False, False, 0)

        card = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        card.get_style_context().add_class("tracker-card")
        card.set_margin_start(20)
        card.set_margin_end(20)
        self._year_title = Gtk.Label(xalign=0)
        self._year_title.get_style_context().add_class("tracker-title")
        card.pack_start(self._year_title, False, False, 0)
        self.heatmap = Heatmap(cell=12, gap=3, on_select=self._select)
        self.heatmap.set_halign(Gtk.Align.START)
        card.pack_start(self.heatmap, False, False, 0)
        outer.pack_start(card, False, False, 0)

        self._day_box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self._day_box.set_border_width(20)
        outer.pack_start(self._day_box, False, False, 0)
        self.add(outer)

        app.subscribe(self.refresh)
        # Statuses move with the clock (a window opens, another is missed).
        self._tick = GLib.timeout_add_seconds(30, lambda: (self.refresh(), True)[1])
        self.connect("destroy", self._closed)
        self.refresh()

    def _closed(self, *_) -> None:
        self.app.unsubscribe(self.refresh)
        GLib.source_remove(self._tick)

    def refresh(self) -> None:
        records = self.app.history(YEAR)
        if records == self._records:
            return
        self._records = records
        if self._selected is None or all(r.day != self._selected for r in records):
            self._selected = records[0].day if records else None
        self._fill_summary(records)
        self._year_title.set_text(year_footer(records))
        self.heatmap.set_records(records, footer="")
        self.heatmap.select(self._selected)
        self._fill_day()

    def _select(self, key: str) -> None:
        self._selected = key
        self._fill_day()

    # MARK: - Summary

    def _fill_summary(self, records: list) -> None:
        for child in self._summary_box.get_children():
            self._summary_box.remove(child)
        current = tracker.streak(records)
        streak = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=0)
        streak.pack_start(_label(str(current), "tracker-streak", xalign=0), False, False, 0)
        streak.pack_start(_label("day streak", "tracker-caption", xalign=0), False, False, 0)
        self._summary_box.pack_start(streak, False, False, 0)
        figures = [(f"{tracker.longest_streak(records)}", "longest streak, in days")]
        for title, span in (("this week", 7), ("last 30 days", 30), ("this year", len(records))):
            ratio = tracker.on_time_ratio(records[:span])
            figures.append(("—" if ratio is None else f"{round(ratio * 100)}%", f"on time · {title}"))
        # Packed from the right, so they read left to right in order.
        for value, caption in reversed(figures):
            figure = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=2)
            figure.set_valign(Gtk.Align.CENTER)
            figure.pack_start(_label(value, "tracker-figure", xalign=0), False, False, 0)
            figure.pack_start(_label(caption, "tracker-caption", xalign=0), False, False, 0)
            self._summary_box.pack_end(figure, False, False, 0)
        self._summary_box.show_all()

    # MARK: - The day picked

    def _fill_day(self) -> None:
        from .tray import ACCENTS
        from .tracker import windows
        for child in self._day_box.get_children():
            self._day_box.remove(child)
        record = next((r for r in self._records or () if r.day == self._selected), None)
        if record is None:
            return
        y, m, d = (int(x) for x in record.day.split("-"))
        day = _date(y, m, d)
        is_today = record.day == self._records[0].day
        title = "Today" if is_today else f"{day.strftime('%A')}, {day.day} {day.strftime('%B %Y')}"
        header = Gtk.Box(spacing=12)
        header.pack_start(_label(title, "tracker-title", xalign=0), False, False, 0)
        header.pack_start(_label(describe(record, is_today), "tracker-caption", xalign=0), False, False, 0)
        self._day_box.pack_start(header, False, False, 0)

        s = self.app.settings
        tz = place_zone(s.active_place)
        times = {w.kind: w for w in windows(make_instant(tz, y, m, d, 12), s)}
        fmt = PrayerFormatter(s.use_24_hour_clock, s.active_place)
        grid = Gtk.Grid(column_spacing=48, row_spacing=6)
        for column, kind in enumerate(PRAYERS):
            status = record.statuses.get(kind, tracker.UNTRACKED)
            dot = Dot(status, ACCENTS.get(kind, (0.3, 0.34, 0.58)))
            dot.set_halign(Gtk.Align.CENTER)
            if status != tracker.UPCOMING:
                dot.connect("button-press-event", self._on_dot, record.day, kind, status)
            grid.attach(_label(NAMES[kind], "tracker-heading"), column, 0, 1, 1)
            window = times.get(kind)
            grid.attach(_label(fmt.time(window.start) if window else "", "tracker-caption"), column, 1, 1, 1)
            grid.attach(dot, column, 2, 1, 1)
            grid.attach(_label(LABELS.get(status, status), "tracker-caption"), column, 3, 1, 1)
        self._day_box.pack_start(grid, False, False, 0)
        self._day_box.show_all()

    def _on_dot(self, dot: Dot, event, day: str, kind: str, status: str) -> bool:
        menu = Gtk.Menu()
        title = Gtk.MenuItem(label=f"{NAMES[kind]} · {LABELS.get(status, status)}")
        title.set_sensitive(False)
        menu.append(title)
        menu.append(Gtk.SeparatorMenuItem())
        for new, label in ((tracker.PRAYED, "Prayed on time"), (tracker.QADA, "Made up (qada)"),
                           (tracker.EXCUSED, "Excused — not owed")):
            item = Gtk.MenuItem(label=label)
            item.set_sensitive(new != status)
            item.connect("activate", lambda *_, n=new: self.app.set_status(day, kind, n))
            menu.append(item)
        if status in tracker.STATUSES:
            menu.append(Gtk.SeparatorMenuItem())
            clear = Gtk.MenuItem(label="Clear")
            clear.connect("activate", lambda *_: self.app.set_status(day, kind, None))
            menu.append(clear)
        menu.show_all()
        menu.attach_to_widget(dot, None)
        self._menu = menu  # held so it is not collected while open
        menu.popup_at_pointer(event)
        return True
