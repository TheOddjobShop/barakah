"""Launch at login — the XDG autostart entry that stands in for SMAppService.

A prayer reminder that only works when the user remembers to open it is not a
prayer reminder, so the toggle in Settings → General writes or removes
~/.config/autostart/dev.justin06lee.barakah.desktop.
"""

from __future__ import annotations

import logging
import os
import shutil

from . import APP_ID

log = logging.getLogger("barakah.login")


def _entry() -> str:
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.expanduser("~/.config")
    return os.path.join(base, "autostart", f"{APP_ID}.desktop")


def _launcher() -> str:
    return shutil.which("barakah") or os.path.expanduser("~/.local/bin/barakah")


def is_enabled() -> bool:
    return os.path.exists(_entry())


def set_enabled(enabled: bool) -> bool:
    path = _entry()
    try:
        if not enabled:
            if os.path.exists(path):
                os.remove(path)
            return True
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as fh:
            fh.write(
                "[Desktop Entry]\n"
                "Type=Application\n"
                "Name=Barakah\n"
                "Comment=Prayer times, iqama reminders, and media that actually stops\n"
                f"Exec={_launcher()} --background\n"
                f"Icon={APP_ID}\n"
                "Terminal=false\n"
                "X-GNOME-Autostart-enabled=true\n"
                "X-GNOME-Autostart-Delay=5\n"
            )
        return True
    except OSError as error:
        log.error("launch at login %s failed: %s", "enable" if enabled else "disable", error)
        return False
