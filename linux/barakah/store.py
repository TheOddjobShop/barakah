"""Owns the single SettingsData value and persists it — SettingsStore.swift.

Writes are debounced: the settings window produces a storm of changes as
spin buttons and sliders move, and there is no reason to hit the disk for each.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Callable

from gi.repository import GLib

from . import paths
from .model import SettingsData

log = logging.getLogger("barakah.settings")


class SettingsStore:
    def __init__(self, path: str | None = None):
        self.path = path or paths.settings_file()
        self.data = self._load()
        self.revision = 0
        self._save_source = 0
        self._listeners: list[Callable[[], None]] = []

    def subscribe(self, listener: Callable[[], None]) -> None:
        self._listeners.append(listener)

    def update(self, mutate: Callable[[SettingsData], None]) -> None:
        """Mutate settings. Everything funnels through here so persistence and
        change notification cannot be forgotten at a call site."""
        before = self.data.to_json()
        copy = self.data.copy()
        mutate(copy)
        if copy.to_json() == before:
            return
        self.data = copy
        self.revision += 1
        self._schedule_save()
        for listener in list(self._listeners):
            listener()

    def update_config(self, kind: str, mutate) -> None:
        def apply(settings: SettingsData) -> None:
            config = settings.config(kind)
            mutate(config)
            settings.prayer_configs[kind] = config
        self.update(apply)

    def reset_to_defaults(self) -> None:
        self.update(lambda s: s.__dict__.update(SettingsData().__dict__))
        self.flush()

    def _load(self) -> SettingsData:
        try:
            with open(self.path, encoding="utf-8") as fh:
                raw = fh.read()
        except FileNotFoundError:
            return SettingsData()
        except OSError as error:
            log.error("settings unreadable: %s", error)
            return SettingsData()
        try:
            return SettingsData.from_json(json.loads(raw))
        except (ValueError, TypeError) as error:
            # A settings file we cannot read is preserved rather than
            # clobbered — it is the only copy of the user's configuration.
            log.error("settings unreadable, starting fresh: %s", error)
            backup = os.path.splitext(self.path)[0] + ".corrupt.json"
            try:
                os.replace(self.path, backup)
            except OSError:
                pass
            return SettingsData()

    def _schedule_save(self) -> None:
        if self._save_source:
            GLib.source_remove(self._save_source)
        self._save_source = GLib.timeout_add(400, self._debounced_save)

    def _debounced_save(self) -> bool:
        self._save_source = 0
        self.flush()
        return False

    def flush(self) -> None:
        """Write immediately. Called on debounce and on quit."""
        if self._save_source:
            GLib.source_remove(self._save_source)
            self._save_source = 0
        tmp = self.path + ".tmp"
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                json.dump(self.data.to_json(), fh, indent=2, sort_keys=True, ensure_ascii=False)
                fh.write("\n")
            os.replace(tmp, self.path)
        except OSError as error:
            log.error("failed to save settings: %s", error)
