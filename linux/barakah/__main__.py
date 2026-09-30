"""Entry point: `barakah` (or `python3 -m barakah`).

A Gtk.Application, so a second launch — from the app grid while the tray is
already running — reaches the running instance and opens Settings instead of
starting a duplicate that would sound every athan twice.
"""

from __future__ import annotations

import argparse
import logging
import signal
import sys

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import Gio, GLib, Gtk  # noqa: E402

from . import APP_ID, DISPLAY_NAME, VERSION  # noqa: E402


class BarakahApplication(Gtk.Application):
    def __init__(self):
        super().__init__(application_id=APP_ID, flags=Gio.ApplicationFlags.HANDLES_COMMAND_LINE)
        self.state = None
        self.tray = None
        self.settings_window = None
        GLib.set_application_name(DISPLAY_NAME)

    def do_startup(self):
        Gtk.Application.do_startup(self)
        from .app import AppState
        from .tray import Tray
        self.hold()  # a tray app has no window keeping it alive
        quit_action = Gio.SimpleAction.new("quit", None)
        quit_action.connect("activate", lambda *_: self.quit())
        self.add_action(quit_action)
        settings_action = Gio.SimpleAction.new("settings", None)
        settings_action.connect("activate", lambda *_: self.open_settings())
        self.add_action(settings_action)
        test_action = Gio.SimpleAction.new("test-athan", GLib.VariantType.new("s"))
        test_action.connect("activate", lambda _a, prayer: self.state.test_athan(prayer.get_string()))
        self.add_action(test_action)
        self.state = AppState()
        self.tray = Tray(self.state, self.open_settings, self.quit)
        self.state.start()
        for sig in (signal.SIGINT, signal.SIGTERM):
            GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, sig, self._on_signal)

    def do_command_line(self, command_line):
        args = command_line.get_arguments()[1:]
        background = "--background" in args
        if "--test-athan" in args:
            index = args.index("--test-athan")
            prayer = args[index + 1] if index + 1 < len(args) and not args[index + 1].startswith("-") else ""
            self.activate_action("test-athan", GLib.Variant("s", prayer))
            return 0
        if "--settings" in args:
            index = args.index("--settings")
            tab = args[index + 1] if index + 1 < len(args) and not args[index + 1].startswith("-") else None
            self.open_settings(tab)
        elif not background and command_line.get_is_remote():
            self.open_settings()
        elif not background and not self.state.settings.has_completed_onboarding:
            self.state.update_settings(lambda s: setattr(s, "has_completed_onboarding", True))
            self.open_settings("location")
        return 0

    def open_settings(self, tab: str | None = None):
        from .settings_ui import SettingsWindow
        if self.settings_window is None:
            self.settings_window = SettingsWindow(self.state)
            self.settings_window.set_application(self)
            self.settings_window.connect("destroy", self._settings_closed)
            self.settings_window.show_all()
        if tab:
            self.settings_window.show_tab(tab)
        self.settings_window.present()

    def _settings_closed(self, *_):
        self.settings_window = None

    def _on_signal(self):
        self.quit()
        return GLib.SOURCE_REMOVE

    def do_shutdown(self):
        if self.state is not None:
            self.state.shutdown()
        Gtk.Application.do_shutdown(self)


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv if argv is None else argv
    parser = argparse.ArgumentParser(prog="barakah", description=f"{DISPLAY_NAME} {VERSION} — prayer times in the tray")
    parser.add_argument("--background", action="store_true", help="start in the tray without opening any window")
    parser.add_argument("--settings", nargs="?", const="", metavar="TAB",
                        help="open Settings, optionally at a tab (location, calculation, iqama, athan, media, "
                             "general), in the running instance if there is one")
    parser.add_argument("--times", action="store_true", help="print today's times and exit")
    parser.add_argument("--test-athan", nargs="?", const="", metavar="PRAYER",
                        help="run the athan moment now, as if PRAYER's time had come (default: the next "
                             "prayer): pause media as configured, play the athan, show the panel")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--version", action="version", version=f"{DISPLAY_NAME} {VERSION}")
    options = parser.parse_args(argv[1:])
    logging.basicConfig(level=logging.DEBUG if options.verbose else logging.INFO,
                        format="barakah %(name)s: %(message)s")
    if options.times:
        from .cli import print_times
        return print_times()
    return BarakahApplication().run(argv)


if __name__ == "__main__":
    sys.exit(main())
