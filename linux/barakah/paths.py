"""Where Barakah keeps things on Linux — the XDG equivalents of the Mac's
Application Support, Caches and bundle resources."""

from __future__ import annotations

import os

_HERE = os.path.dirname(os.path.abspath(__file__))


def _xdg(var: str, fallback: str) -> str:
    value = os.environ.get(var, "")
    return value if os.path.isabs(value) else os.path.expanduser(fallback)


def _ensure(path: str) -> str:
    os.makedirs(path, exist_ok=True)
    return path


def config_dir() -> str:
    """Settings: ~/.config/barakah (the Mac keeps them in Application Support)."""
    return _ensure(os.path.join(_xdg("XDG_CONFIG_HOME", "~/.config"), "barakah"))


def settings_file() -> str:
    return os.path.join(config_dir(), "settings.json")


def data_dir() -> str:
    return _ensure(os.path.join(_xdg("XDG_DATA_HOME", "~/.local/share"), "barakah"))


def athan_dir() -> str:
    """Drop-in recordings: ~/.local/share/barakah/Athan."""
    return _ensure(os.path.join(data_dir(), "Athan"))


def cache_dir() -> str:
    return _ensure(os.path.join(_xdg("XDG_CACHE_HOME", "~/.cache"), "barakah"))


def state_dir() -> str:
    return _ensure(os.path.join(_xdg("XDG_STATE_HOME", "~/.local/state"), "barakah"))


def resources_dir() -> str:
    """Installed: the package's sibling `resources/`. From a checkout: the
    repository's own Resources and assets, found relative to this file."""
    installed = os.path.join(os.path.dirname(_HERE), "resources")
    if os.path.isdir(installed):
        return installed
    return os.path.join(os.path.dirname(_HERE), "data")


def bundled_athan_dirs() -> list[str]:
    dirs = [os.path.join(resources_dir(), "Athan")]
    repo = os.path.join(os.path.dirname(os.path.dirname(_HERE)), "Resources", "Athan")
    if os.path.isdir(repo):
        dirs.append(repo)
    return [d for d in dirs if os.path.isdir(d)]


def icons_dir() -> str:
    installed = os.path.join(resources_dir(), "icons")
    if os.path.isdir(installed):
        return installed
    return os.path.join(os.path.dirname(_HERE), "data", "icons")


def app_icon() -> str:
    for candidate in (os.path.join(resources_dir(), "barakah.svg"),
                      os.path.join(os.path.dirname(os.path.dirname(_HERE)), "assets", "icon.svg")):
        if os.path.exists(candidate):
            return candidate
    return "dev.justin06lee.barakah"
