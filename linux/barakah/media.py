"""Silencing media at athan time, and putting it back — the Linux Media stack.

macOS needs three strategies because it has no public "pause everything"
API. Linux has one: MPRIS, the D-Bus interface every desktop player, browser
tab and the media keys speak. It also answers honestly, which macOS no longer
does — each player reports whether it is really Playing, so Barakah knows
exactly what it paused and resumes only that.

- Pause: an explicit `Pause()` to each MPRIS player that reports Playing and
  is not excluded. Never `PlayPause`: a toggle sent to a stopped player starts
  music in the middle of the adhan.
- Mute ("Pause and mute"): mutes every *other* application's output stream
  through PipeWire (`pw-dump` + `wpctl`), for sources MPRIS cannot reach —
  games, calls, players that never publish. Barakah's own stream stays
  audible. The previous state is persisted, so a crash mid-athan cannot leave
  anything muted after the next launch.
- Resume: `Play()` only to players Barakah paused, and only if they are
  still Paused — if the user already restarted or stopped one, it is left
  alone.
"""

from __future__ import annotations

import json
import logging
import os
import shutil
import subprocess
from dataclasses import dataclass, field
from typing import Optional

from gi.repository import Gio, GLib

from . import paths
from .model import SettingsData, mutes_output, pauses_players

log = logging.getLogger("barakah.media")

MPRIS_PREFIX = "org.mpris.MediaPlayer2."
MPRIS_PATH = "/org/mpris/MediaPlayer2"
PLAYER_IFACE = "org.mpris.MediaPlayer2.Player"
ROOT_IFACE = "org.mpris.MediaPlayer2"


@dataclass
class Player:
    bus_name: str
    identity: str
    status: str
    can_pause: bool
    title: Optional[str] = None
    artist: Optional[str] = None

    @property
    def short_name(self) -> str:
        """The name used in the exclusion list: `spotify`, `firefox`, `vlc`…
        Browsers append `.instance_1_23` per process; that part is dropped."""
        name = self.bus_name[len(MPRIS_PREFIX):]
        return name.split(".instance", 1)[0]

    @property
    def description(self) -> str:
        if self.title and self.artist:
            return f"{self.title} — {self.artist}"
        return self.title or self.identity


@dataclass
class MediaInterruption:
    paused_players: list = field(default_factory=list)   # (bus_name, identity)
    sources_at_interruption: list = field(default_factory=list)
    muted_output: bool = False
    now_playing_description: Optional[str] = None

    @property
    def did_anything(self) -> bool:
        return bool(self.paused_players) or self.muted_output

    @property
    def summary(self) -> Optional[str]:
        parts = []
        if self.paused_players:
            parts.append("Paused " + formatted_list([identity for _, identity in self.paused_players]))
        if self.muted_output:
            parts.append("other audio muted")
        return ", ".join(parts) if parts else None


def formatted_list(names: list) -> str:
    if not names:
        return ""
    if len(names) == 1:
        return names[0]
    if len(names) == 2:
        return f"{names[0]} and {names[1]}"
    return ", ".join(names[:-1]) + " and " + names[-1]


# MARK: - MPRIS


class Mpris:
    def __init__(self):
        try:
            self.bus = Gio.bus_get_sync(Gio.BusType.SESSION, None)
        except GLib.Error as error:
            log.error("no session bus: %s", error.message)
            self.bus = None

    @property
    def available(self) -> bool:
        return self.bus is not None

    def _get(self, name: str, iface: str, prop: str):
        try:
            result = self.bus.call_sync(name, MPRIS_PATH, "org.freedesktop.DBus.Properties", "Get",
                                        GLib.Variant("(ss)", (iface, prop)), GLib.VariantType("(v)"),
                                        Gio.DBusCallFlags.NONE, 800, None)
            return result.unpack()[0]
        except GLib.Error:
            return None

    def players(self) -> list[Player]:
        if not self.bus:
            return []
        try:
            names = self.bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus",
                                       "org.freedesktop.DBus", "ListNames", None,
                                       GLib.VariantType("(as)"), Gio.DBusCallFlags.NONE, 1000, None).unpack()[0]
        except GLib.Error as error:
            log.error("ListNames failed: %s", error.message)
            return []
        found = []
        for name in sorted(n for n in names if n.startswith(MPRIS_PREFIX)):
            status = self._get(name, PLAYER_IFACE, "PlaybackStatus") or "Stopped"
            identity = self._get(name, ROOT_IFACE, "Identity") or name[len(MPRIS_PREFIX):]
            can_pause = self._get(name, PLAYER_IFACE, "CanPause")
            metadata = self._get(name, PLAYER_IFACE, "Metadata") or {}
            artist = metadata.get("xesam:artist")
            if isinstance(artist, list):
                artist = ", ".join(artist) or None
            found.append(Player(name, identity, status, can_pause is not False,
                                metadata.get("xesam:title") or None, artist or None))
        return found

    def send(self, bus_name: str, method: str) -> bool:
        try:
            self.bus.call_sync(bus_name, MPRIS_PATH, PLAYER_IFACE, method, None, None,
                               Gio.DBusCallFlags.NONE, 1500, None)
            return True
        except GLib.Error as error:
            log.warning("%s.%s failed: %s", bus_name, method, error.message)
            return False

    def status(self, bus_name: str) -> Optional[str]:
        return self._get(bus_name, PLAYER_IFACE, "PlaybackStatus")


# MARK: - PipeWire streams


@dataclass
class Stream:
    node_id: int
    pid: Optional[int]
    name: str
    running: bool
    muted: bool


class StreamMuter:
    """Mutes other applications' output streams, never the device — so the
    athan itself stays audible — and remembers exactly what it touched."""

    def __init__(self):
        self.available = bool(shutil.which("pw-dump") and shutil.which("wpctl"))
        self.marker = os.path.join(paths.state_dir(), "output-mute-state.json")
        self.muted: list[dict] = []

    def streams(self) -> list[Stream]:
        if not shutil.which("pw-dump"):
            return []
        try:
            result = subprocess.run(["pw-dump"], capture_output=True, text=True, timeout=5)
            objects = json.loads(result.stdout or "[]")
        except (OSError, subprocess.TimeoutExpired, ValueError) as error:
            log.warning("pw-dump failed: %s", error)
            return []
        # Native PipeWire clients (pw-play, GStreamer's pipewiresink) carry
        # their pid on the client object rather than on the stream node, so
        # resolve through the client — otherwise Barakah's own athan stream
        # would look foreign and be muted along with everything else.
        client_pids = {}
        for obj in objects:
            if obj.get("type") == "PipeWire:Interface:Client":
                props = (obj.get("info") or {}).get("props") or {}
                client_pids[obj.get("id")] = props.get("application.process.id") or props.get("pipewire.sec.pid")
        streams = []
        for obj in objects:
            if obj.get("type") != "PipeWire:Interface:Node":
                continue
            info = obj.get("info") or {}
            props = info.get("props") or {}
            if props.get("media.class") != "Stream/Output/Audio":
                continue
            pid = props.get("application.process.id") or client_pids.get(props.get("client.id"))
            try:
                pid = int(pid) if pid is not None else None
            except (TypeError, ValueError):
                pid = None
            name = props.get("application.name") or props.get("node.name") or f"stream {obj.get('id')}"
            muted = False
            for param in (info.get("params") or {}).get("Props") or []:
                if isinstance(param, dict) and "mute" in param:
                    muted = bool(param["mute"])
            streams.append(Stream(int(obj["id"]), pid, name, info.get("state") == "running", muted))
        return streams

    def playing_applications(self) -> list[str]:
        """Applications currently producing sound — the per-process audio
        activity macOS reads from CoreAudio."""
        own = os.getpid()
        names = []
        for s in self.streams():
            if s.running and s.pid != own and s.name not in names:
                names.append(s.name)
        return names

    def mute(self) -> bool:
        if not self.available or self.muted:
            return False
        own = os.getpid()
        for s in self.streams():
            if s.pid == own or s.muted:
                continue
            if self._set(s.node_id, True):
                self.muted.append({"id": s.node_id, "pid": s.pid, "name": s.name})
        self._persist()
        return bool(self.muted)

    def restore(self) -> None:
        current = {s.node_id: s for s in self.streams()}
        for entry in self.muted:
            stream = current.get(entry["id"])
            # A reused node id belonging to another process is not ours.
            if stream is not None and stream.pid == entry.get("pid"):
                self._set(entry["id"], False)
        self.muted = []
        self._persist()

    def recover_if_needed(self) -> None:
        """Undo a mute left behind by a run that died mid-athan."""
        try:
            with open(self.marker, encoding="utf-8") as fh:
                self.muted = json.load(fh)
        except (OSError, ValueError):
            return
        log.info("restoring streams muted by a previous run")
        self.restore()

    def _persist(self) -> None:
        try:
            if self.muted:
                with open(self.marker, "w", encoding="utf-8") as fh:
                    json.dump(self.muted, fh)
            elif os.path.exists(self.marker):
                os.remove(self.marker)
        except OSError as error:
            log.error("could not record mute state: %s", error)

    @staticmethod
    def _set(node_id: int, muted: bool) -> bool:
        try:
            result = subprocess.run(["wpctl", "set-mute", str(node_id), "1" if muted else "0"],
                                    capture_output=True, timeout=5)
            return result.returncode == 0
        except (OSError, subprocess.TimeoutExpired):
            return False


# MARK: - Controller


@dataclass
class MediaDiagnostics:
    mpris_available: bool
    players: list
    mute_available: bool
    audio_sources: list


class MediaController:
    def __init__(self):
        self.mpris = Mpris()
        self.muter = StreamMuter()
        self.active: Optional[MediaInterruption] = None

    @property
    def can_pause_media(self) -> bool:
        return self.mpris.available

    def interrupt(self, mode: str, settings: SettingsData) -> MediaInterruption:
        if not (pauses_players(mode) or mutes_output(mode)):
            return MediaInterruption()
        # Anything still paused from a previous athan is released first, so
        # the record of what to resume never straddles two prayers.
        if self.active is not None:
            self.resume(force=True)

        interruption = MediaInterruption()
        excluded = {x.lower() for x in settings.media_excluded_bundle_ids}
        interruption.sources_at_interruption = self.muter.playing_applications()

        if settings.use_media_remote and self.mpris.available:
            for player in self.mpris.players():
                if player.status != "Playing" or not player.can_pause:
                    continue
                if player.short_name.lower() in excluded or player.identity.lower() in excluded:
                    continue
                if self.mpris.send(player.bus_name, "Pause"):
                    interruption.paused_players.append((player.bus_name, player.identity))
                    interruption.now_playing_description = interruption.now_playing_description or player.description

        if mutes_output(mode) and self.muter.mute():
            interruption.muted_output = True

        self.active = interruption if interruption.did_anything else None
        log.info("interrupted media: %s", interruption.summary or "nothing was playing")
        return interruption

    def resume(self, force: bool = False) -> None:
        interruption = self.active
        if interruption is None:
            if force and self.muter.muted:
                self.muter.restore()
            return
        self.active = None
        if interruption.muted_output:
            self.muter.restore()
        for bus_name, _identity in interruption.paused_players:
            if self.mpris.status(bus_name) == "Paused":
                self.mpris.send(bus_name, "Play")
        log.info("resumed media")

    def forget(self) -> None:
        """Drop the record without touching playback — "don't resume"."""
        if self.active is not None and self.active.muted_output:
            self.muter.restore()
        self.active = None

    def diagnostics(self) -> MediaDiagnostics:
        return MediaDiagnostics(
            mpris_available=self.mpris.available,
            players=self.mpris.players(),
            mute_available=self.muter.available,
            audio_sources=self.muter.playing_applications(),
        )
