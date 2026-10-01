"""The settings window — SettingsView, SettingsPrayerTabs and MediaSettingsView
from the macOS app, as a GTK notebook with the same six tabs."""

from __future__ import annotations

import subprocess
from typing import Callable

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gio, GLib, Gtk  # noqa: E402

from . import APP_ID, DISPLAY_NAME, VERSION, paths  # noqa: E402
from .audio import AthanLibrary  # noqa: E402
from .model import (  # noqa: E402
    HIGH_LATITUDE_LABELS, MADHAB_DESCRIPTIONS, MADHAB_LABELS, MEDIA_PAUSE_LABELS, MEDIA_PAUSE_MODES,
    MENU_BAR_STYLE_LABELS, MENU_BAR_STYLES, METHOD_LABELS, NAMES, PRAYER_KINDS, PRAYERS, SELECTABLE_METHODS,
    AthanSound, IqamaRule, LockRule, MediaResumeMode, PlaceSetting, PrayerLockSettings, SettingsData,
)


def _note(text: str) -> Gtk.Label:
    label = Gtk.Label(label=text, xalign=0, wrap=True, max_width_chars=64)
    label.get_style_context().add_class("dim-label")
    return label


def _heading(text: str) -> Gtk.Label:
    label = Gtk.Label(xalign=0)
    label.set_markup(f"<b>{GLib.markup_escape_text(text)}</b>")
    label.set_margin_top(10)
    return label


def _combo(options: list[tuple[str, str]], active: str, on_change: Callable[[str], None]) -> Gtk.ComboBoxText:
    combo = Gtk.ComboBoxText()
    for key, label in options:
        combo.append(key, label)
    combo.set_active_id(active)
    combo.connect("changed", lambda c: c.get_active_id() is not None and on_change(c.get_active_id()))
    return combo


def _spin(value: int, lo: int, hi: int, on_change: Callable[[int], None]) -> Gtk.SpinButton:
    spin = Gtk.SpinButton.new_with_range(lo, hi, 1)
    spin.set_value(value)
    spin.connect("value-changed", lambda s: on_change(int(s.get_value())))
    return spin


def _check(label: str, active: bool, on_change: Callable[[bool], None]) -> Gtk.CheckButton:
    check = Gtk.CheckButton(label=label)
    check.set_active(active)
    check.connect("toggled", lambda c: on_change(c.get_active()))
    return check


def _row(label: str, widget: Gtk.Widget) -> Gtk.Box:
    box = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=12)
    box.pack_start(Gtk.Label(label=label, xalign=0), True, True, 0)
    box.pack_end(widget, False, False, 0)
    return box


def _page() -> Gtk.Box:
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
    box.set_border_width(18)
    return box


def _scrolled(child: Gtk.Widget) -> Gtk.ScrolledWindow:
    scroller = Gtk.ScrolledWindow()
    scroller.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
    scroller.add(child)
    return scroller


class SettingsWindow(Gtk.Window):
    def __init__(self, app):
        super().__init__(title=f"{DISPLAY_NAME} Settings")
        self.app = app
        self.set_default_size(620, 640)
        self.set_icon_name(APP_ID)
        self.notebook: Gtk.Notebook | None = None
        self._status_labels: dict[str, Gtk.Label] = {}
        self._build()
        app.subscribe(self._refresh_status)
        self.connect("destroy", lambda *_: app.unsubscribe(self._refresh_status))

    @property
    def s(self) -> SettingsData:
        return self.app.settings

    def update(self, mutate: Callable[[SettingsData], None]) -> None:
        self.app.update_settings(mutate)

    def update_config(self, kind: str, mutate) -> None:
        self.app.update_config(kind, mutate)

    TABS = ("location", "calculation", "iqama", "athan", "media", "lock", "general")

    def show_tab(self, name: str) -> None:
        if name in self.TABS:
            self.notebook.set_current_page(self.TABS.index(name))

    def _build(self) -> None:
        if self.notebook is not None:
            self.remove(self.notebook)
        page = self.notebook.get_current_page() if self.notebook else 0
        self.notebook = Gtk.Notebook()
        for title, build in (("Location", self._location), ("Calculation", self._calculation),
                             ("Iqama", self._iqama), ("Athan", self._athan),
                             ("Media", self._media), ("Lock", self._lock), ("General", self._general)):
            self.notebook.append_page(_scrolled(build()), Gtk.Label(label=title))
        self.add(self.notebook)
        self.notebook.show_all()
        self.notebook.set_current_page(page)
        self._refresh_status()

    # MARK: - Location

    def _location(self) -> Gtk.Box:
        box = _page()
        auto = Gtk.RadioButton.new_with_label(None, "Use my location")
        manual = Gtk.RadioButton.new_with_label_from_widget(auto, "Set manually")
        (auto if self.s.location_mode == "automatic" else manual).set_active(True)

        def mode_changed(button, mode):
            if button.get_active():
                self.update(lambda s: setattr(s, "location_mode", mode))
                if mode == "automatic":
                    self.app.location.refresh()
        auto.connect("toggled", mode_changed, "automatic")
        manual.connect("toggled", mode_changed, "manual")
        box.pack_start(auto, False, False, 0)
        box.pack_start(manual, False, False, 0)

        self._status_labels["detected"] = Gtk.Label(xalign=0, wrap=True)
        box.pack_start(self._status_labels["detected"], False, False, 0)
        buttons = Gtk.Box(spacing=8)
        update = Gtk.Button(label="Update now")
        update.connect("clicked", lambda *_: self.app.location.refresh())
        privacy = Gtk.Button(label="Open Privacy Settings")
        privacy.connect("clicked", lambda *_: _spawn(["gnome-control-center", "location"]))
        buttons.pack_start(update, False, False, 0)
        buttons.pack_start(privacy, False, False, 0)
        box.pack_start(buttons, False, False, 0)

        box.pack_start(_heading("Search for a city"), False, False, 0)
        search = Gtk.SearchEntry(placeholder_text="City name, e.g. Sunnyvale")
        results = Gtk.ListBox()
        results.set_selection_mode(Gtk.SelectionMode.NONE)

        def run_search(*_):
            for child in results.get_children():
                results.remove(child)
            places = self.app.location.search(search.get_text())
            if not places and len(search.get_text().strip()) >= 2:
                results.add(Gtk.Label(label="No matching city in the offline database. "
                                            "Enter coordinates below instead.", xalign=0))
            for place in places:
                button = Gtk.Button()
                button.set_relief(Gtk.ReliefStyle.NONE)
                label = Gtk.Label(xalign=0)
                label.set_markup(f"{GLib.markup_escape_text(place.name)}\n<small>"
                                 f"{place.short_coordinate_description} · {place.time_zone_identifier}</small>")
                button.add(label)
                button.connect("clicked", lambda _b, p=place: self._pin(p, manual))
                results.add(button)
            results.show_all()
        search.connect("activate", run_search)
        search.connect("search-changed", run_search)
        box.pack_start(search, False, False, 0)
        box.pack_start(results, False, False, 0)

        expander = Gtk.Expander(label="Enter coordinates")
        grid = Gtk.Grid(column_spacing=8, row_spacing=6, margin_top=6)
        place = self.s.manual_place
        name = Gtk.Entry(text=place.name)
        lat = Gtk.Entry(text=str(place.latitude))
        lon = Gtk.Entry(text=str(place.longitude))
        tz = Gtk.Entry(text=place.time_zone_identifier, placeholder_text="e.g. America/Los_Angeles")
        for i, (label, entry) in enumerate((("Name", name), ("Latitude", lat), ("Longitude", lon), ("Time zone", tz))):
            grid.attach(Gtk.Label(label=label, xalign=0), 0, i, 1, 1)
            grid.attach(entry, 1, i, 1, 1)
        error = Gtk.Label(xalign=0)
        use = Gtk.Button(label="Use these")

        def use_coordinates(*_):
            try:
                la, lo = float(lat.get_text()), float(lon.get_text())
                if not (-90 <= la <= 90 and -180 <= lo <= 180):
                    raise ValueError
            except ValueError:
                error.set_text("Latitude must be −90…90 and longitude −180…180.")
                return
            error.set_text("")
            self._pin(PlaceSetting(name.get_text().strip() or "Custom place", la, lo, tz.get_text().strip()), manual)
        use.connect("clicked", use_coordinates)
        grid.attach(use, 1, 4, 1, 1)
        grid.attach(error, 0, 5, 2, 1)
        expander.add(grid)
        box.pack_start(expander, False, False, 0)

        box.pack_start(_heading("In use"), False, False, 0)
        self._status_labels["in-use"] = Gtk.Label(xalign=0, selectable=True)
        box.pack_start(self._status_labels["in-use"], False, False, 0)
        return box

    def _pin(self, place: PlaceSetting, manual_radio: Gtk.RadioButton) -> None:
        def apply(s: SettingsData) -> None:
            s.manual_place = place
            s.location_mode = "manual"
        self.update(apply)
        manual_radio.set_active(True)

    # MARK: - Calculation

    def _calculation(self) -> Gtk.Box:
        box = _page()
        box.pack_start(_row("Method", _combo([(m, METHOD_LABELS[m]) for m in SELECTABLE_METHODS],
                                             self.s.calculation_method,
                                             lambda v: self.update(lambda s: setattr(s, "calculation_method", v)))),
                       False, False, 0)
        box.pack_start(_note("Methods differ in the sun's angle below the horizon used for Fajr and Isha. "
                             "Use whichever your local masjid follows."), False, False, 0)

        box.pack_start(_heading("Asr"), False, False, 0)
        madhab_note = _note(MADHAB_DESCRIPTIONS[self.s.madhab])

        def set_madhab(v: str) -> None:
            self.update(lambda s: setattr(s, "madhab", int(v)))
            madhab_note.set_text(MADHAB_DESCRIPTIONS[int(v)])
        box.pack_start(_row("Madhab", _combo([(str(k), v) for k, v in MADHAB_LABELS.items()],
                                             str(self.s.madhab), set_madhab)), False, False, 0)
        box.pack_start(madhab_note, False, False, 0)

        box.pack_start(_heading("High latitudes"), False, False, 0)
        options = [("default", "Method default")] + [(k, v) for k, v in HIGH_LATITUDE_LABELS.items()]
        box.pack_start(_row("Rule", _combo(options, self.s.high_latitude_rule or "default",
                                           lambda v: self.update(lambda s: setattr(
                                               s, "high_latitude_rule", None if v == "default" else v)))),
                       False, False, 0)

        box.pack_start(_heading("Fine adjustment"), False, False, 0)
        box.pack_start(_note("Minutes added to each calculated time, for matching a printed masjid timetable exactly."),
                       False, False, 0)
        for kind in PRAYER_KINDS:
            spin = _spin(self.s.config(kind).athan_adjustment_minutes, -30, 30,
                         lambda v, k=kind: self.update_config(k, lambda c: setattr(c, "athan_adjustment_minutes", v)))
            box.pack_start(_row(NAMES[kind], spin), False, False, 0)
        return box

    # MARK: - Iqama

    def _iqama_editor(self, rule: IqamaRule, on_change: Callable[[IqamaRule], None],
                      allow_off: bool = True) -> Gtk.Box:
        box = Gtk.Box(spacing=6)
        kinds = ([("none", "Off")] if allow_off else []) + [("offset", "After athan"), ("fixed", "Fixed time")]
        minutes = _spin(rule.minutes if rule.kind == "offset" else 10, 0, 120, lambda _v: emit())
        hour = _spin(rule.hour if rule.kind == "fixed" else 13, 0, 23, lambda _v: emit())
        minute = _spin(rule.minute if rule.kind == "fixed" else 30, 0, 59, lambda _v: emit())
        hour.set_wrap(True)
        minute.set_wrap(True)
        minute.connect("output", _two_digits)
        suffix = Gtk.Label(label="min")
        colon = Gtk.Label(label=":")
        combo = Gtk.ComboBoxText()
        for key, label in kinds:
            combo.append(key, label)
        combo.set_active_id(rule.kind if rule.kind in dict(kinds) else kinds[0][0])

        def sync_visibility():
            kind = combo.get_active_id()
            for w in (minutes, suffix):
                w.set_visible(kind == "offset")
            for w in (hour, colon, minute):
                w.set_visible(kind == "fixed")

        def emit():
            kind = combo.get_active_id()
            sync_visibility()
            if kind == "offset":
                on_change(IqamaRule.offset(int(minutes.get_value())))
            elif kind == "fixed":
                on_change(IqamaRule.fixed(int(hour.get_value()), int(minute.get_value())))
            else:
                on_change(IqamaRule.off())
        combo.connect("changed", lambda *_: emit())
        for w in (combo, minutes, suffix, hour, colon, minute):
            box.pack_start(w, False, False, 0)
        box.connect("map", lambda *_: sync_visibility())
        return box

    def _iqama(self) -> Gtk.Box:
        box = _page()
        box.pack_start(_note("Iqama is set by your masjid, so Barakah cannot work it out. Give it either an "
                             "offset after the athan or a fixed time."), False, False, 0)
        for kind in PRAYERS:
            config = self.s.config(kind)
            box.pack_start(_heading(NAMES[kind]), False, False, 0)
            box.pack_start(_row("Iqama", self._iqama_editor(
                config.iqama_rule, lambda r, k=kind: self.update_config(k, lambda c: setattr(c, "iqama_rule", r)))),
                False, False, 0)
            box.pack_start(_row("Remind me before iqama (minutes, 0 = off)", _spin(
                config.iqama_reminder_minutes, 0, 60,
                lambda v, k=kind: self.update_config(k, lambda c: setattr(c, "iqama_reminder_minutes", v)))),
                False, False, 0)
            box.pack_start(_check("Also notify at iqama itself", config.iqama_alert_enabled,
                                  lambda v, k=kind: self.update_config(k, lambda c: setattr(c, "iqama_alert_enabled", v))),
                           False, False, 0)

        box.pack_start(_heading("Jumu'ah"), False, False, 0)
        box.pack_start(_check("Use a separate time on Fridays", self.s.jumuah_enabled,
                              lambda v: self.update(lambda s: setattr(s, "jumuah_enabled", v))), False, False, 0)
        box.pack_start(_row("Iqama", self._iqama_editor(
            self.s.jumuah_iqama_rule, lambda r: self.update(lambda s: setattr(s, "jumuah_iqama_rule", r)),
            allow_off=False)), False, False, 0)
        box.pack_start(_row("Remind me before khutbah (minutes)", _spin(
            self.s.jumuah_reminder_minutes, 0, 90,
            lambda v: self.update(lambda s: setattr(s, "jumuah_reminder_minutes", v)))), False, False, 0)
        box.pack_start(_note("Replaces Dhuhr's iqama on Fridays only."), False, False, 0)
        return box

    # MARK: - Athan

    def _sound_combo(self, current: AthanSound, on_change: Callable[[AthanSound], None]) -> Gtk.ComboBoxText:
        combo = Gtk.ComboBoxText()
        combo.append("chime", "Chime (built in)")
        for name in AthanLibrary.available():
            combo.append(f"bundled:{name}", AthanSound.bundled(name).label)
        if current.kind == "custom":
            combo.append("custom", current.label)
        combo.append("choose", "Choose a file…")
        combo.append("silent", "Silent")
        active = {"chime": "chime", "silent": "silent", "custom": "custom"}.get(current.kind, f"bundled:{current.name}")
        if active.startswith("bundled:") and current.name not in AthanLibrary.available():
            combo.append(active, f"{current.label} (missing)")
        combo.set_active_id(active)
        previous = [active]

        def changed(c):
            key = c.get_active_id()
            if key is None or key == previous[0]:
                return
            if key == "choose":
                sound = self._choose_file()
                if sound is None:
                    c.set_active_id(previous[0])
                    return
                on_change(sound)
                GLib.idle_add(lambda: (self._build(), False)[1])
                return
            previous[0] = key
            if key in ("chime", "silent"):
                on_change(AthanSound(key, ""))
            elif key.startswith("bundled:"):
                on_change(AthanSound.bundled(key.split(":", 1)[1]))
        combo.connect("changed", changed)
        return combo

    def _choose_file(self):
        dialog = Gtk.FileChooserNative.new("Choose an athan recording", self, Gtk.FileChooserAction.OPEN, None, None)
        audio = Gtk.FileFilter()
        audio.set_name("Audio")
        audio.add_mime_type("audio/*")
        dialog.add_filter(audio)
        result = dialog.run()
        path = dialog.get_filename() if result == Gtk.ResponseType.ACCEPT else None
        dialog.destroy()
        return AthanSound.custom_path(path) if path else None

    def _athan(self) -> Gtk.Box:
        box = _page()
        box.pack_start(_heading("Sound"), False, False, 0)
        box.pack_start(_row("Athan", self._sound_combo(
            self.s.athan_sound, lambda v: self.update(lambda s: setattr(s, "athan_sound", v)))), False, False, 0)

        fajr_combo = self._sound_combo(self.s.fajr_athan_sound or self.s.athan_sound,
                                       lambda v: self.update(lambda s: setattr(s, "fajr_athan_sound", v)))
        fajr_row = _row("Fajr", fajr_combo)

        def fajr_toggle(v: bool) -> None:
            self.update(lambda s: setattr(s, "fajr_athan_sound", s.athan_sound if v else None))
            fajr_row.set_sensitive(v)
        box.pack_start(_check("Use a different sound for Fajr", self.s.fajr_athan_sound is not None, fajr_toggle),
                       False, False, 0)
        fajr_row.set_sensitive(self.s.fajr_athan_sound is not None)
        box.pack_start(fajr_row, False, False, 0)
        box.pack_start(_note("The Fajr athan includes the extra line “prayer is better than sleep”, "
                             "so it is usually a separate recording."), False, False, 0)

        buttons = Gtk.Box(spacing=8)
        preview = Gtk.Button(label="Preview")

        def toggle_preview(*_):
            if self.app.audio.previewing or self.app.audio.is_playing:
                self.app.audio.stop(notify=False)
            else:
                self.app.audio.preview(self.s.athan_sound, self.s.athan_volume)
            self._refresh_status()
        preview.connect("clicked", toggle_preview)
        self._preview_button = preview
        folder = Gtk.Button(label="Open the Athan folder")
        folder.connect("clicked", lambda *_: Gio.AppInfo.launch_default_for_uri(
            GLib.filename_to_uri(paths.athan_dir(), None), None))
        buttons.pack_start(preview, False, False, 0)
        buttons.pack_start(folder, False, False, 0)
        box.pack_start(buttons, False, False, 0)
        box.pack_start(_note(f"Add your own recordings to {paths.athan_dir()} and they appear here. "
                             "Every recording is level-matched on playback."), False, False, 0)
        self._status_labels["audio-error"] = Gtk.Label(xalign=0, wrap=True)
        box.pack_start(self._status_labels["audio-error"], False, False, 0)

        box.pack_start(_heading("Volume"), False, False, 0)
        volume = Gtk.Scale.new_with_range(Gtk.Orientation.HORIZONTAL, 0, 1, 0.05)
        volume.set_value(self.s.athan_volume)
        volume.set_draw_value(False)
        volume.connect("value-changed", lambda w: self.update(lambda s: setattr(s, "athan_volume", round(w.get_value(), 2))))
        box.pack_start(volume, False, False, 0)
        box.pack_start(_row("Stop automatically after (seconds, 0 = play it whole)", _spin(
            self.s.athan_max_seconds, 0, 600,
            lambda v: self.update(lambda s: setattr(s, "athan_max_seconds", v)))), False, False, 0)

        box.pack_start(_heading("Which prayers"), False, False, 0)
        for kind in PRAYERS:
            box.pack_start(_check(NAMES[kind], self.s.config(kind).athan_enabled,
                                  lambda v, k=kind: self.update_config(k, lambda c: setattr(c, "athan_enabled", v))),
                           False, False, 0)
        box.pack_start(_check("Show a floating window while the athan plays", self.s.show_athan_window,
                              lambda v: self.update(lambda s: setattr(s, "show_athan_window", v))), False, False, 10)
        return box

    # MARK: - Media

    def _media(self) -> Gtk.Box:
        box = _page()
        box.pack_start(_heading("When the athan starts"), False, False, 0)
        options = [(m, MEDIA_PAUSE_LABELS[m]) for m in MEDIA_PAUSE_MODES]
        for kind in PRAYERS:
            box.pack_start(_row(NAMES[kind], _combo(options, self.s.config(kind).media_mode,
                                                    lambda v, k=kind: self.update_config(
                                                        k, lambda c: setattr(c, "media_mode", v)))),
                           False, False, 0)

        box.pack_start(_heading("Afterwards"), False, False, 0)
        resume = self.s.resume_mode
        minutes = _spin(resume.minutes if resume.kind == "afterMinutes" else 5, 1, 60,
                        lambda v: self.update(lambda s: setattr(s, "resume_mode", MediaResumeMode("afterMinutes", v))))

        def set_resume(kind: str) -> None:
            minutes.set_sensitive(kind == "afterMinutes")
            value = MediaResumeMode(kind, int(minutes.get_value()) if kind == "afterMinutes" else 0)
            self.update(lambda s: setattr(s, "resume_mode", value))
        resume_options = [("never", "Don't resume"), ("afterAthan", "When the athan ends"),
                          ("afterMinutes", "Some minutes after the athan"), ("afterIqama", "At iqama time")]
        box.pack_start(_row("Resume what was paused", _combo(resume_options, resume.kind, set_resume)), False, False, 0)
        minutes.set_sensitive(resume.kind == "afterMinutes")
        box.pack_start(_row("Minutes after the athan", minutes), False, False, 0)
        box.pack_start(_note("Only players Barakah actually paused are resumed, and only if they are still "
                             "paused — resuming never starts something you had stopped yourself."), False, False, 0)

        box.pack_start(_heading("How"), False, False, 0)
        box.pack_start(_check("Pause media players (MPRIS)", self.s.use_media_remote,
                              lambda v: self.update(lambda s: setattr(s, "use_media_remote", v))), False, False, 0)
        box.pack_start(_note("Reaches browsers, Spotify, VLC, mpv and anything the keyboard's play/pause key "
                             "controls. Barakah only ever sends Pause, never a toggle."), False, False, 0)
        excluded = Gtk.Entry(text=", ".join(self.s.media_excluded_bundle_ids),
                             placeholder_text="e.g. spotify, firefox")
        excluded.connect("changed", lambda e: self.update(lambda s: setattr(
            s, "media_excluded_bundle_ids", [x.strip() for x in e.get_text().split(",") if x.strip()])))
        box.pack_start(_row("Never pause", excluded), False, False, 0)

        box.pack_start(_heading("What works on this machine"), False, False, 0)
        report = Gtk.Label(xalign=0, wrap=True, selectable=True)
        report.set_text("Run a check to see which methods are available.")
        buttons = Gtk.Box(spacing=8)
        check = Gtk.Button(label="Check now")

        def probe(*_):
            d = self.app.media.diagnostics()
            lines = [f"MPRIS (session D-Bus): {'available' if d.mpris_available else 'unavailable'}"]
            if d.players:
                for p in d.players:
                    lines.append(f"  • {p.identity} ({p.short_name}) — {p.status}"
                                 + (f": {p.description}" if p.status == "Playing" else ""))
            else:
                lines.append("  No media players are running.")
            lines.append(f"Muting other audio (PipeWire): {'available' if d.mute_available else 'unavailable — needs pw-dump and wpctl'}")
            lines.append("Producing sound now: " + (", ".join(d.audio_sources) if d.audio_sources else "nothing"))
            report.set_text("\n".join(lines))
        check.connect("clicked", probe)
        test = Gtk.Button(label="Test pause")
        test.connect("clicked", lambda *_: (self.app.media.interrupt("pause", self.s), probe()))
        again = Gtk.Button(label="Resume")
        again.connect("clicked", lambda *_: (self.app.resume_media_now(), probe()))
        for b in (check, test, again):
            buttons.pack_start(b, False, False, 0)
        box.pack_start(report, False, False, 0)
        box.pack_start(buttons, False, False, 0)
        return box

    # MARK: - Prayer lock

    def update_lock(self, mutate: Callable[[PrayerLockSettings], None]) -> None:
        def apply(s: SettingsData) -> None:
            lock = s.lock
            mutate(lock)
            s.prayer_lock = lock
        self.update(apply)

    def _lock(self) -> Gtk.Box:
        box = _page()
        lock = self.s.lock
        box.pack_start(_check("Lock the screen at prayer times", lock.enabled,
                              lambda v: self.update_lock(lambda l: setattr(l, "enabled", v))), False, False, 0)
        box.pack_start(_note(
            "Once a prayer's grace period has passed, every screen is covered until you click "
            "“Wallahi, I prayed …”, or until the prayer's time ends. Confirming from the top bar "
            "before then means it never appears."), False, False, 0)

        box.pack_start(_heading("Grace period, in minutes after the athan"), False, False, 0)
        grid = Gtk.Grid(column_spacing=16, row_spacing=6)
        for row, kind in enumerate(PRAYERS):
            rule = lock.rule(kind)

            def set_rule(kind=kind, **change):
                def apply(l: PrayerLockSettings) -> None:
                    current = l.rule(kind)
                    l.rules[kind] = LockRule(change.get("enabled", current.enabled),
                                             change.get("grace_minutes", current.grace_minutes))
                self.update_lock(apply)

            grid.attach(_check(NAMES[kind], rule.enabled, lambda v, f=set_rule: f(enabled=v)), 0, row, 1, 1)
            spin = _spin(rule.grace_minutes, 0, 120, lambda v, f=set_rule: f(grace_minutes=v))
            grid.attach(spin, 1, row, 1, 1)
        box.pack_start(grid, False, False, 0)

        box.pack_start(_heading("See it"), False, False, 0)
        preview = Gtk.Button(label="Preview the lock")
        preview.set_halign(Gtk.Align.START)
        preview.connect("clicked", lambda *_: self.get_application().activate_action("preview-lock", None))
        box.pack_start(preview, False, False, 0)
        box.pack_start(_note("The preview records nothing and lifts by itself after a minute."), False, False, 0)

        box.pack_start(_heading("Tracker"), False, False, 0)

        def set_widget(v: bool) -> None:
            def apply(s: SettingsData) -> None:
                widget = s.widget
                widget.enabled = v
                s.tracker_widget = widget
            self.update(apply)
        box.pack_start(_check("Show the prayer heatmap on the desktop", self.s.widget.enabled, set_widget),
                       False, False, 0)
        tracker_button = Gtk.Button(label="Open the prayer tracker")
        tracker_button.set_halign(Gtk.Align.START)
        tracker_button.connect("clicked", lambda *_: self.get_application().activate_action("tracker", None))
        box.pack_start(tracker_button, False, False, 0)
        return box

    # MARK: - General

    def _general(self) -> Gtk.Box:
        box = _page()
        box.pack_start(_check("Launch Barakah at login", self.s.launch_at_login,
                              lambda v: self.update(lambda s: setattr(s, "launch_at_login", v))), False, False, 0)

        box.pack_start(_heading("Top bar"), False, False, 0)
        box.pack_start(_row("Show", _combo([(k, MENU_BAR_STYLE_LABELS[k]) for k in MENU_BAR_STYLES],
                                           self.s.menu_bar_style,
                                           lambda v: self.update(lambda s: setattr(s, "menu_bar_style", v)))),
                       False, False, 0)
        for label, attr in (("Use a 24-hour clock", "use_24_hour_clock"), ("Show the Hijri date", "show_hijri_date"),
                            ("Show sunrise in the list", "show_sunrise")):
            box.pack_start(_check(label, getattr(self.s, attr),
                                  lambda v, a=attr: self.update(lambda s: setattr(s, a, v))), False, False, 0)

        box.pack_start(_heading("Notifications"), False, False, 0)
        box.pack_start(_check("Notify when a prayer time arrives", self.s.notify_at_athan,
                              lambda v: self.update(lambda s: setattr(s, "notify_at_athan", v))), False, False, 0)
        box.pack_start(_check("Play the notification sound too", self.s.notification_sound_enabled,
                              lambda v: self.update(lambda s: setattr(s, "notification_sound_enabled", v))),
                       False, False, 0)
        if self.app.notifications.prescheduled:
            text = ("Iqama reminders are always delivered as notifications, and are scheduled ahead of time "
                    "as systemd user timers so they still arrive if Barakah is not running.")
        else:
            text = ("This system has no systemd user instance, so notifications are posted by Barakah while it "
                    "runs. Turn on Launch at login so they are never missed.")
        box.pack_start(_note(text), False, False, 0)

        reset = Gtk.Button(label="Reset all settings")

        def do_reset(*_):
            self.app.reset_settings()
            self._build()
        reset.connect("clicked", do_reset)
        footer = Gtk.Box(spacing=8, margin_top=16)
        footer.pack_start(reset, False, False, 0)
        footer.pack_end(Gtk.Label(label=f"{DISPLAY_NAME} {VERSION}"), False, False, 0)
        box.pack_start(footer, False, False, 0)
        return box

    # MARK: - Live status

    def _refresh_status(self) -> None:
        labels = self._status_labels
        loc = self.app.location
        s = self.s
        if "detected" in labels:
            if s.location_mode == "automatic":
                if loc.is_resolving:
                    text = "Finding your location…"
                elif loc.last_error:
                    text = f"Location unavailable: {loc.last_error}\nUsing {s.active_place.name} until a fix arrives."
                elif s.resolved_place:
                    text = f"Detected: {s.resolved_place.name}"
                else:
                    text = "No location yet."
            else:
                text = "Using the place you pinned below."
            labels["detected"].set_text(text)
        if "in-use" in labels:
            place = s.active_place
            labels["in-use"].set_text(f"Place: {place.name}\nCoordinates: {place.short_coordinate_description}\n"
                                      f"Time zone: {place.time_zone_identifier or 'system'}")
        if "audio-error" in labels:
            labels["audio-error"].set_text(self.app.audio.last_error or "")
        if getattr(self, "_preview_button", None) is not None:
            busy = self.app.audio.previewing or self.app.audio.is_playing
            self._preview_button.set_label("Stop" if busy else "Preview")


def _two_digits(spin: Gtk.SpinButton) -> bool:
    spin.set_text(f"{int(spin.get_value()):02d}")
    return True


def _spawn(argv: list[str]) -> None:
    try:
        subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    except OSError:
        pass
