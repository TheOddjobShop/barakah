"""The prayer heatmap: a year of days as GitHub draws contributions — a
column a week, Sunday at the top, each day as green as it was kept.

Drawn whole in one DrawingArea (month and weekday labels, the cells, the
"Less … More" key) so the tracker window and the desktop widget show the same
thing. Records come from tracker.history, newest first; a day's shade is
tracker.heat. Hover a day for what it held; click it to pick it.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import date as _date, timedelta
from typing import Callable, Optional

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("PangoCairo", "1.0")
from gi.repository import Gdk, Gtk, Pango, PangoCairo  # noqa: E402

from . import tracker  # noqa: E402

WEEKS = 53
DAYS = WEEKS * 7  # enough history to fill every column

# GitHub's own greens, empty first.
PALETTES = {
    "dark": {
        "levels": ("#161b22", "#0e4429", "#006d32", "#26a641", "#39d353"),
        "text": "#8b949e", "selected": "#e6edf3",
    },
    "light": {
        "levels": ("#ebedf0", "#9be9a8", "#40c463", "#30a14e", "#216e39"),
        "text": "#57606a", "selected": "#24292f",
    },
}
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")
WEEKDAY_LABELS = {1: "Mon", 3: "Wed", 5: "Fri"}  # rows, Sunday = 0


def _rgba(hex_colour: str, alpha: float = 1.0) -> tuple:
    value = hex_colour.lstrip("#")
    return tuple(int(value[i:i + 2], 16) / 255 for i in (0, 2, 4)) + (alpha,)


def _parse(key: str) -> _date:
    y, m, d = (int(x) for x in key.split("-"))
    return _date(y, m, d)


def describe(record: tracker.DayRecord, today: bool = False) -> str:
    """"4 of 5 on time · 1 made up", as a tooltip says it."""
    found = tracker.heat(record)
    if found is None:
        return "Before tracking began"
    parts = []
    if found.on_time == len(record.statuses):
        parts.append("All five on time")
    else:
        parts.append(f"{found.on_time} of {len(record.statuses)} on time")
    if found.made_up:
        parts.append(f"{found.made_up} made up")
    if found.excused:
        parts.append(f"{found.excused} excused")
    if found.missed:
        parts.append(f"{found.missed} missed")
    if today and found.on_time + found.made_up + found.excused + found.missed < len(record.statuses):
        parts.append("so far")
    return " · ".join(parts)


@dataclass(frozen=True)
class Cell:
    column: int
    row: int
    day: _date
    record: tracker.DayRecord


class Heatmap(Gtk.DrawingArea):
    """`palette` is "dark", "light", or None to follow the theme."""

    def __init__(self, cell: int = 11, gap: int = 3, palette: Optional[str] = None,
                 on_select: Optional[Callable[[str], None]] = None, footer: str = ""):
        super().__init__()
        self.cell, self.gap, self.palette = cell, gap, palette
        self.on_select = on_select
        self.footer = footer
        self.selected: Optional[str] = None
        self._cells: list[Cell] = []
        self._columns = WEEKS
        self._first_sunday: Optional[_date] = None
        self._today: Optional[_date] = None
        self.left = round(cell * 2.7)
        self.top = round(cell * 1.6)
        self.bottom = round(cell * 2.6)
        self.set_has_tooltip(True)
        self.add_events(Gdk.EventMask.BUTTON_PRESS_MASK | Gdk.EventMask.POINTER_MOTION_MASK)
        self.connect("draw", self._draw)
        self.connect("query-tooltip", self._tooltip)
        self.connect("button-press-event", self._pressed)
        self._resize()

    # MARK: - Data

    def set_records(self, records: list, footer: Optional[str] = None) -> None:
        """`records` newest first, as tracker.history returns them."""
        if footer is not None:
            self.footer = footer
        if not records:
            self._cells = []
            self.queue_draw()
            return
        today = _parse(records[0].day)
        start = today - timedelta(days=WEEKS * 7 - 7)
        first_sunday = start - timedelta(days=(start.weekday() + 1) % 7)
        cells = []
        for record in records:
            day = _parse(record.day)
            if day < first_sunday:
                continue
            offset = (day - first_sunday).days
            cells.append(Cell(offset // 7, offset % 7, day, record))
        self._cells = cells
        self._today = today
        self._first_sunday = first_sunday
        self._columns = (today - first_sunday).days // 7 + 1
        self._resize()
        self.queue_draw()

    def select(self, key: Optional[str]) -> None:
        self.selected = key
        self.queue_draw()

    def _resize(self) -> None:
        step = self.cell + self.gap
        self.set_size_request(self.left + self._columns * step - self.gap + 2,
                              self.top + 7 * step - self.gap + self.bottom)

    # MARK: - Drawing

    def _colours(self) -> dict:
        if self.palette in PALETTES:
            return PALETTES[self.palette]
        fg = self.get_style_context().get_color(Gtk.StateFlags.NORMAL)
        luminance = 0.2126 * fg.red + 0.7152 * fg.green + 0.0722 * fg.blue
        return PALETTES["dark" if luminance > 0.5 else "light"]

    def _origin(self, cell: Cell) -> tuple:
        step = self.cell + self.gap
        return self.left + cell.column * step, self.top + cell.row * step

    def _layout(self, text: str) -> Pango.Layout:
        layout = self.create_pango_layout(text)
        font = self.get_pango_context().get_font_description().copy()
        font.set_size(int(max(7, self.cell * 0.82) * Pango.SCALE))
        layout.set_font_description(font)
        return layout

    def _text(self, cr, text: str, x: float, y: float, colour: tuple, align: str = "left") -> None:
        layout = self._layout(text)
        width, height = layout.get_pixel_size()
        if align == "right":
            x -= width
        cr.set_source_rgba(*colour)
        cr.move_to(x, y - height / 2)
        PangoCairo.show_layout(cr, layout)

    @staticmethod
    def _rounded(cr, x: float, y: float, size: float, radius: float) -> None:
        cr.new_sub_path()
        cr.arc(x + size - radius, y + radius, radius, -1.5708, 0)
        cr.arc(x + size - radius, y + size - radius, radius, 0, 1.5708)
        cr.arc(x + radius, y + size - radius, radius, 1.5708, 3.1416)
        cr.arc(x + radius, y + radius, radius, 3.1416, 4.7124)
        cr.close_path()

    def _draw(self, _widget, cr) -> bool:
        colours = self._colours()
        text = _rgba(colours["text"])
        levels = colours["levels"]
        step = self.cell + self.gap
        radius = max(1.5, self.cell / 5)

        # Month labels over the first week that starts in each month, unless
        # it would crowd the next one, as GitHub does.
        if self._first_sunday is not None:
            labels = []
            previous = None
            for column in range(self._columns):
                sunday = self._first_sunday + timedelta(days=7 * column)
                if sunday.month != previous:
                    labels.append((column, MONTHS[sunday.month - 1]))
                    previous = sunday.month
            for index, (column, name) in enumerate(labels):
                following = labels[index + 1][0] if index + 1 < len(labels) else self._columns + 3
                if following - column < 3:
                    continue
                self._text(cr, name, self.left + column * step, self.top / 2, text)

        for row, name in WEEKDAY_LABELS.items():
            self._text(cr, name, 0, self.top + row * step + self.cell / 2, text)

        for cell in self._cells:
            x, y = self._origin(cell)
            found = tracker.heat(cell.record)
            if found is None:
                cr.set_source_rgba(*_rgba(levels[0], 0.45))
            else:
                cr.set_source_rgba(*_rgba(levels[found.level]))
            self._rounded(cr, x, y, self.cell, radius)
            cr.fill()
            if cell.record.day == self.selected:
                cr.set_source_rgba(*_rgba(colours["selected"], 0.9))
                cr.set_line_width(1.5)
                self._rounded(cr, x - 1, y - 1, self.cell + 2, radius + 1)
                cr.stroke()

        # Footer: what the year held on the left, the key on the right.
        footer_y = self.top + 7 * step - self.gap + self.bottom / 2 + 2
        if self.footer:
            self._text(cr, self.footer, self.left, footer_y, text)
        right = self.left + self._columns * step - self.gap
        self._text(cr, "More", right, footer_y, text, align="right")
        x = right - self._layout("More").get_pixel_size()[0] - 6 - self.cell
        for level in reversed(range(len(levels))):
            cr.set_source_rgba(*_rgba(levels[level]))
            self._rounded(cr, x, footer_y - self.cell / 2, self.cell, radius)
            cr.fill()
            x -= self.cell + self.gap
        self._text(cr, "Less", x + self.cell + self.gap - 6, footer_y, text, align="right")
        return False

    # MARK: - Pointer

    def _cell_at(self, x: float, y: float) -> Optional[Cell]:
        for cell in self._cells:
            cx, cy = self._origin(cell)
            if cx <= x < cx + self.cell + self.gap and cy <= y < cy + self.cell + self.gap:
                return cell
        return None

    def _tooltip(self, _widget, x, y, _keyboard, tooltip) -> bool:
        cell = self._cell_at(x, y)
        if cell is None:
            return False
        when = f"{cell.day.strftime('%A')}, {cell.day.day} {cell.day.strftime('%B %Y')}"
        tooltip.set_text(f"{describe(cell.record, cell.day == self._today)}\n{when}")
        return True

    def _pressed(self, _widget, event) -> bool:
        if event.button != 1 or self.on_select is None:
            return False
        cell = self._cell_at(event.x, event.y)
        if cell is None:
            return False
        self.select(cell.record.day)
        self.on_select(cell.record.day)
        return True


def year_footer(records: list) -> str:
    """"1,243 prayers on time in the last year"."""
    on_time = sum(list(r.statuses.values()).count(tracker.PRAYED) for r in records)
    return f"{on_time:,} prayer{'' if on_time == 1 else 's'} on time in the last year"
