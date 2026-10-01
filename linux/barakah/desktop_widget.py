"""The prayer heatmap as a desktop widget — TrackerWidget.swift on the Mac.

GNOME has no widget layer, so this is what Conky-style widgets are there: an
undecorated window kept below every other, on every workspace, out of the
taskbar and Alt+Tab. It draws its own GitHub-dark card (rounded, on a
transparent window where there is a compositor). Drag it anywhere; where it
was left is kept in the state directory, not in settings, because screen
coordinates mean nothing on another machine. Right-click for the tracker or
to take it off the desktop.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Callable, Optional

import cairo
import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk  # noqa: E402

from . import paths, tracker  # noqa: E402
from .heatmap import DAYS as YEAR, Heatmap, describe, year_footer  # noqa: E402

log = logging.getLogger("barakah.widget")

CARD = (0.051, 0.067, 0.090)      # #0d1117
BORDER = (0.188, 0.212, 0.239)    # #30363d
RADIUS = 10

CSS = b"""
.barakah-widget label { color: #8b949e; font-size: 12px; }
.barakah-widget .widget-title { color: #e6edf3; font-size: 14px; font-weight: 600; }
.barakah-widget .widget-streak { color: #39d353; font-size: 13px; font-weight: 600; }
"""


def _label(text: str, *classes: str, xalign: float = 0) -> Gtk.Label:
    label = Gtk.Label(label=text, xalign=xalign)
    for name in classes:
        label.get_style_context().add_class(name)
    return label


class DesktopWidget(Gtk.Window):
    def __init__(self, app, open_tracker: Callable[[], None]):
        super().__init__(title="Barakah — prayers")
        self.app = app
        self.open_tracker = open_tracker
        self._records: Optional[list] = None
        self._save_source = 0
        self._menu: Optional[Gtk.Menu] = None

        self.set_decorated(False)
        self.set_keep_below(True)
        self.set_skip_taskbar_hint(True)
        self.set_skip_pager_hint(True)
        self.set_accept_focus(False)
        self.set_focus_on_map(False)
        self.set_resizable(False)
        self.stick()
        self.get_style_context().add_class("barakah-widget")
        screen = self.get_screen()
        visual = screen.get_rgba_visual()
        self._transparent = visual is not None and screen.is_composited()
        if self._transparent:
            self.set_visual(visual)
        self.set_app_paintable(True)
        self.connect("draw", self._draw_card)

        provider = Gtk.CssProvider()
        provider.load_from_data(CSS)
        Gtk.StyleContext.add_provider_for_screen(screen, provider, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10)
        box.set_border_width(18)
        header = Gtk.Box(spacing=12)
        self._title = _label("", "widget-title")
        self._streak = _label("", "widget-streak", xalign=1)
        header.pack_start(self._title, False, False, 0)
        header.pack_end(self._streak, False, False, 0)
        box.pack_start(header, False, False, 0)
        self.heatmap = Heatmap(cell=10, gap=3, palette="dark")
        box.pack_start(self.heatmap, False, False, 0)
        self.add(box)

        self.add_events(Gdk.EventMask.BUTTON_PRESS_MASK)
        self.connect("button-press-event", self._pressed)
        self.connect("configure-event", self._moved)

        app.subscribe(self.refresh)
        self._tick = GLib.timeout_add_seconds(60, lambda: (self.refresh(), True)[1])
        self.connect("destroy", self._closed)
        self.refresh()
        # Its size is only known once it is mapped; place it then, once.
        self._placed = False
        self.connect("map-event", self._first_map)

    def _closed(self, *_) -> None:
        self.app.unsubscribe(self.refresh)
        GLib.source_remove(self._tick)
        if self._save_source:
            GLib.source_remove(self._save_source)
            self._save_position()

    # MARK: - Content

    def refresh(self) -> None:
        records = self.app.history(YEAR)
        if records == self._records:
            return
        self._records = records
        self._title.set_text(year_footer(records))
        days = tracker.streak(records)
        self._streak.set_text(f"{days}-day streak" if days else "No streak yet")
        self.heatmap.set_records(records, footer=f"Today: {describe(records[0], today=True)}" if records else "")

    def _draw_card(self, widget, cr) -> bool:
        w, h = widget.get_allocated_width(), widget.get_allocated_height()
        if self._transparent:
            cr.set_operator(cairo.OPERATOR_CLEAR)
            cr.paint()
            cr.set_operator(cairo.OPERATOR_OVER)
            radius = RADIUS
        else:
            radius = 0
        inset = 0.5
        cr.new_sub_path()
        cr.arc(w - radius - inset, radius + inset, radius, -1.5708, 0)
        cr.arc(w - radius - inset, h - radius - inset, radius, 0, 1.5708)
        cr.arc(radius + inset, h - radius - inset, radius, 1.5708, 3.1416)
        cr.arc(radius + inset, radius + inset, radius, 3.1416, 4.7124)
        cr.close_path()
        cr.set_source_rgba(*CARD, 0.96)
        cr.fill_preserve()
        cr.set_source_rgb(*BORDER)
        cr.set_line_width(1)
        cr.stroke()
        return False

    # MARK: - Moving it

    def _first_map(self, *_) -> bool:
        if not self._placed:
            self._placed = True
            self._place()
        return False

    def _place(self) -> None:
        position = _load_position()
        if position is not None:
            self.move(*position)
            return
        # Bottom right of the primary monitor, clear of the dock and edge.
        display = Gdk.Display.get_default()
        monitor = display.get_primary_monitor() or display.get_monitor(0)
        area = monitor.get_workarea()
        width, height = self.get_size()
        self.move(area.x + area.width - width - 32, area.y + area.height - height - 32)

    def _pressed(self, _widget, event) -> bool:
        if event.button == 1 and event.type == Gdk.EventType.BUTTON_PRESS:
            self.begin_move_drag(event.button, int(event.x_root), int(event.y_root), event.time)
            return True
        if event.button == 3:
            menu = Gtk.Menu()
            tracker_item = Gtk.MenuItem(label="Open prayer tracker")
            tracker_item.connect("activate", lambda *_: self.open_tracker())
            menu.append(tracker_item)
            hide = Gtk.MenuItem(label="Remove from desktop")
            hide.connect("activate", lambda *_: self._remove())
            menu.append(hide)
            menu.show_all()
            menu.attach_to_widget(self, None)
            self._menu = menu
            menu.popup_at_pointer(event)
            return True
        return False

    def _remove(self) -> None:
        def apply(s) -> None:
            widget = s.widget
            widget.enabled = False
            s.tracker_widget = widget
        self.app.update_settings(apply)

    def _moved(self, *_) -> bool:
        if self._save_source:
            GLib.source_remove(self._save_source)
        self._save_source = GLib.timeout_add(600, self._save_position)
        return False

    def _save_position(self) -> bool:
        self._save_source = 0
        x, y = self.get_position()
        path = paths.widget_position_file()
        try:
            with open(path + ".tmp", "w", encoding="utf-8") as fh:
                json.dump({"x": x, "y": y}, fh)
            os.replace(path + ".tmp", path)
        except OSError as error:
            log.warning("could not keep the widget's position: %s", error)
        return False


def _load_position() -> Optional[tuple]:
    try:
        with open(paths.widget_position_file(), encoding="utf-8") as fh:
            data = json.load(fh)
        return int(data["x"]), int(data["y"])
    except (OSError, ValueError, KeyError, TypeError):
        return None
