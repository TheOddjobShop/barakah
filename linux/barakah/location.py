"""Where the user is, and finding a place by name — LocationService.swift.

Automatic location comes from GeoClue, the desktop's location service (the
Linux counterpart of CoreLocation). GNOME asks the user once, and honours the
Location Services switch in Settings → Privacy. Naming a fix and searching for
a city use libgweather's world database, which is on the machine: unlike the
Mac's CLGeocoder, neither makes a network request.
"""

from __future__ import annotations

import logging
from typing import Callable, Optional

import gi
from gi.repository import Gio, GLib

from . import APP_ID
from .engine import system_timezone_identifier
from .model import PlaceSetting

log = logging.getLogger("barakah.location")

try:
    gi.require_version("GWeather", "4.0")
    from gi.repository import GWeather  # noqa: E402
except (ValueError, ImportError):
    GWeather = None

try:
    gi.require_version("Geoclue", "2.0")
    from gi.repository import Geoclue  # noqa: E402
except (ValueError, ImportError):
    Geoclue = None


def _level(loc, name: str) -> bool:
    return loc.get_level() == getattr(GWeather.LocationLevel, name)


def _describe(loc) -> Optional[PlaceSetting]:
    if not loc.has_coords():
        return None
    lat, lon = loc.get_coords()
    parts = [loc.get_name()]
    parent = loc.get_parent()
    while parent is not None and not _level(parent, "WORLD") and not _level(parent, "REGION"):
        if _level(parent, "ADM1") or _level(parent, "COUNTRY"):
            name = parent.get_name()
            if name and (not parts or parts[-1].lower() != name.lower()):
                parts.append(name)
        parent = parent.get_parent()
    tz = loc.get_timezone_str() or ""
    return PlaceSetting(", ".join(p for p in parts if p), float(lat), float(lon), tz or system_timezone_identifier())


class LocationService:
    def __init__(self):
        self.is_resolving = False
        self.last_error: Optional[str] = None
        self.on_resolve: Optional[Callable[[PlaceSetting], None]] = None
        self.on_change: Optional[Callable[[], None]] = None
        self._simple = None
        self._cities: Optional[list] = None

    # MARK: - Automatic

    @property
    def available(self) -> bool:
        return Geoclue is not None

    @staticmethod
    def location_services_enabled() -> Optional[bool]:
        """GNOME's Privacy → Location switch, or None off GNOME."""
        source = Gio.SettingsSchemaSource.get_default()
        if source is None or source.lookup("org.gnome.system.location", True) is None:
            return None
        return Gio.Settings.new("org.gnome.system.location").get_boolean("enabled")

    def refresh(self) -> None:
        """Ask for a fresh fix. Harmless to call repeatedly."""
        if Geoclue is None:
            self.last_error = "GeoClue is not installed (gir1.2-geoclue-2.0)."
            self._changed()
            return
        if self.location_services_enabled() is False:
            self.last_error = "Location Services are off in Settings → Privacy → Location."
            self._changed()
            return
        if self.is_resolving:
            return
        self.is_resolving = True
        self._changed()
        # Kilometre accuracy is ample: times shift about a minute per 20 km.
        Geoclue.Simple.new(APP_ID, Geoclue.AccuracyLevel.CITY, None, self._on_simple)

    def _on_simple(self, _source, result) -> None:
        try:
            self._simple = Geoclue.Simple.new_finish(result)
        except GLib.Error as error:
            self.is_resolving = False
            self.last_error = error.message
            log.info("location unavailable: %s", error.message)
            self._changed()
            return
        self._simple.connect("notify::location", lambda *_: self._on_location())
        self._on_location()

    def _on_location(self) -> None:
        loc = self._simple.get_location() if self._simple else None
        if loc is None:
            return
        lat, lon = loc.get_property("latitude"), loc.get_property("longitude")
        self.is_resolving = False
        self.last_error = None
        # Name it from the offline database; never let naming block the
        # coordinates, which are all the times need.
        place = PlaceSetting("Current location", lat, lon, system_timezone_identifier())
        nearest = self.nearest_city(lat, lon)
        if nearest is not None:
            place = PlaceSetting(nearest.name, lat, lon, nearest.time_zone_identifier)
        if self.on_resolve:
            self.on_resolve(place)
        self._changed()

    def _changed(self) -> None:
        if self.on_change:
            self.on_change()

    # MARK: - Places database

    def nearest_city(self, lat: float, lon: float) -> Optional[PlaceSetting]:
        if GWeather is None:
            return None
        city = GWeather.Location.get_world().find_nearest_city(lat, lon)
        return _describe(city) if city is not None else None

    def _all_cities(self) -> list:
        if self._cities is None:
            self._cities = []
            if GWeather is not None:
                stack = [GWeather.Location.get_world()]
                while stack:
                    loc = stack.pop()
                    child = loc.next_child(None)
                    while child is not None:
                        if _level(child, "CITY"):
                            self._cities.append(child)
                        stack.append(child)
                        child = loc.next_child(child)
        return self._cities

    def search(self, query: str, limit: int = 25) -> list[PlaceSetting]:
        text = query.strip().lower()
        if len(text) < 2:
            return []
        head = text.split(",")[0].strip()
        scored = []
        for city in self._all_cities():
            name = (city.get_name() or "").lower()
            english = (city.get_english_name() or "").lower()
            if name.startswith(head) or english.startswith(head):
                rank = 0
            elif head in name or head in english:
                rank = 1
            else:
                continue
            place = _describe(city)
            if place is None:
                continue
            # "Springfield, Illinois" narrows by whatever follows the comma.
            rest = text[len(head):].strip(" ,")
            if rest and rest not in place.name.lower():
                continue
            scored.append((rank, place.name, place))
        scored.sort(key=lambda item: (item[0], item[1]))
        seen, out = set(), []
        for _, name, place in scored:
            if name in seen:
                continue
            seen.add(name)
            out.append(place)
            if len(out) >= limit:
                break
        return out
