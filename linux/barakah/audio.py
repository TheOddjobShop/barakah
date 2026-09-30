"""Plays the athan — AudioService, AthanLibrary, AudioNormalizer and
ChimeSynthesiser from the macOS app, on GStreamer.

Barakah plays audio itself rather than as a notification sound, for the same
reasons as on macOS: notification sounds are short and cannot be stopped,
while a real adhan runs two to four minutes and must stop on one click.
"""

from __future__ import annotations

import json
import logging
import math
import os
import struct
import threading
import wave
from typing import Callable, Optional

import gi

gi.require_version("Gst", "1.0")
from gi.repository import GLib, Gst  # noqa: E402

from . import paths  # noqa: E402
from .model import AthanSound, SettingsData  # noqa: E402

log = logging.getLogger("barakah.audio")

SUPPORTED_EXTENSIONS = ("m4a", "mp3", "caf", "wav", "aiff", "aif", "ogg", "opus", "flac")

_gst_ready = False


def ensure_gst() -> None:
    global _gst_ready
    if not _gst_ready:
        Gst.init(None)
        _gst_ready = True


# MARK: - Library


class AthanLibrary:
    """Recordings available to play: the user's own in
    ~/.local/share/barakah/Athan first, then those shipped with Barakah."""

    @staticmethod
    def _files(directory: str) -> list[str]:
        try:
            names = sorted(os.listdir(directory))
        except OSError:
            return []
        return [os.path.join(directory, n) for n in names
                if not n.startswith(".") and n.rsplit(".", 1)[-1].lower() in SUPPORTED_EXTENSIONS]

    @classmethod
    def installed(cls) -> list[str]:
        return cls._files(paths.athan_dir())

    @classmethod
    def bundled(cls) -> list[str]:
        files = []
        for directory in paths.bundled_athan_dirs():
            files += cls._files(directory)
        return files

    @classmethod
    def available(cls) -> list[str]:
        names = {os.path.splitext(os.path.basename(p))[0] for p in cls.installed() + cls.bundled()}
        return sorted(names)

    @classmethod
    def path(cls, name: str) -> Optional[str]:
        """Prefer the user's copy, so a file of theirs named like a bundled
        recording overrides it."""
        for candidate in cls.installed() + cls.bundled():
            if os.path.splitext(os.path.basename(candidate))[0] == name:
                return candidate
        return None


# MARK: - Chime


class Chime:
    """A struck bell, three times, rendered once to a cached WAV — the same
    partials, decays and strike spacing as ChimeSynthesiser.swift."""

    SAMPLE_RATE = 44_100
    PARTIALS = ((1.000, 0.55, 1.9), (2.008, 0.30, 1.5), (2.414, 0.18, 1.2),
                (3.011, 0.12, 0.9), (4.166, 0.07, 0.7), (5.433, 0.04, 0.5))
    FUNDAMENTAL = 587.33
    STRIKES = 3
    STRIKE_INTERVAL = 1.7
    TAIL = 2.6
    _lock = threading.Lock()

    @classmethod
    def path(cls) -> str:
        target = os.path.join(paths.cache_dir(), "chime-v1.wav")
        with cls._lock:
            if not os.path.exists(target):
                cls._render(target)
        return target

    @classmethod
    def warm(cls) -> None:
        threading.Thread(target=cls.path, daemon=True, name="barakah-chime").start()

    @classmethod
    def _render(cls, target: str) -> None:
        sr = cls.SAMPLE_RATE
        frames = int(((cls.STRIKES - 1) * cls.STRIKE_INTERVAL + cls.TAIL) * sr)
        mix = [0.0] * frames
        for strike in range(cls.STRIKES):
            onset = int(round(strike * cls.STRIKE_INTERVAL * sr))
            gain = 0.78 ** strike
            for ratio, amplitude, decay in cls.PARTIALS:
                # Envelope and phase advance by a constant factor per sample,
                # which keeps pure Python fast enough to render in a second.
                omega = 2 * math.pi * cls.FUNDAMENTAL * ratio / sr
                rot_c, rot_s = math.cos(omega), math.sin(omega)
                fall = math.exp(-1.0 / (decay * sr))
                c, s, env = 1.0, 0.0, amplitude * gain
                attack_frames = 0.004 * sr
                for i in range(frames - onset):
                    attack = 1.0 if i >= attack_frames else i / attack_frames
                    mix[onset + i] += s * env * attack
                    c, s = c * rot_c - s * rot_s, s * rot_c + c * rot_s
                    env *= fall
        tmp = target + ".tmp"
        with wave.open(tmp, "wb") as out:
            out.setnchannels(2)
            out.setsampwidth(2)
            out.setframerate(sr)
            data = bytearray()
            for sample in mix:
                value = int(max(-1.0, min(1.0, math.tanh(sample * 0.8) * 0.72)) * 32767)
                data += struct.pack("<hh", value, value)
            out.writeframes(bytes(data))
        os.replace(tmp, target)
        log.debug("rendered chime to %s", target)


# MARK: - Loudness


class Normalizer:
    """How much to turn a recording up or down so every athan lands near the
    same loudness. Recordings in the wild span −27 to −9 dBFS; without this
    the volume slider means nothing.

    Measured with GStreamer's `level` element: an energy-weighted mean over
    10 ms blocks that actually contain sound, the same approximation the Mac
    computes sample by sample. Cached on disk by path and modification time.
    """

    TARGET_DB = -16.0
    MAX_GAIN = 6.0
    MIN_GAIN = 0.05
    SILENCE_DB = 20 * math.log10(0.0005)
    _lock = threading.Lock()

    @classmethod
    def _cache_file(cls) -> str:
        return os.path.join(paths.cache_dir(), "loudness.json")

    @classmethod
    def _key(cls, path: str) -> str:
        try:
            return f"{path}#{os.path.getmtime(path)}"
        except OSError:
            return path

    @classmethod
    def gain(cls, path: str) -> float:
        key = cls._key(path)
        with cls._lock:
            try:
                with open(cls._cache_file(), encoding="utf-8") as fh:
                    cache = json.load(fh)
            except (OSError, ValueError):
                cache = {}
            if key in cache:
                return float(cache[key])
            measured = cls._measure(path)
            value = measured if measured is not None else 1.0
            cache[key] = value
            try:
                with open(cls._cache_file(), "w", encoding="utf-8") as fh:
                    json.dump(cache, fh, indent=1)
            except OSError:
                pass
            return value

    @classmethod
    def warm(cls, files: list[str]) -> None:
        def run():
            for f in files:
                cls.gain(f)
        threading.Thread(target=run, daemon=True, name="barakah-loudness").start()

    @classmethod
    def _measure(cls, path: str) -> Optional[float]:
        ensure_gst()
        try:
            pipeline = Gst.parse_launch(
                "uridecodebin name=src ! audioconvert ! audio/x-raw,format=F32LE "
                "! level interval=10000000 post-messages=true ! fakesink sync=false")
        except GLib.Error as error:
            log.warning("cannot measure %s: %s", path, error.message)
            return None
        pipeline.get_by_name("src").set_property("uri", Gst.filename_to_uri(path))
        bus = pipeline.get_bus()
        pipeline.set_state(Gst.State.PLAYING)
        energy, counted = 0.0, 0
        try:
            while True:
                msg = bus.timed_pop_filtered(10 * Gst.SECOND, Gst.MessageType.ELEMENT | Gst.MessageType.EOS
                                             | Gst.MessageType.ERROR)
                if msg is None or msg.type in (Gst.MessageType.EOS, Gst.MessageType.ERROR):
                    if msg is not None and msg.type == Gst.MessageType.ERROR:
                        log.warning("measuring %s failed: %s", path, msg.parse_error()[0].message)
                    break
                structure = msg.get_structure()
                if structure is None or structure.get_name() != "level":
                    continue
                rms = structure.get_value("rms")
                if not rms:
                    continue
                # Mean energy across channels for this block.
                block = sum(10 ** (db / 10) for db in rms) / len(rms)
                if block > 10 ** (cls.SILENCE_DB / 10):
                    energy += block
                    counted += 1
        finally:
            pipeline.set_state(Gst.State.NULL)
        if counted == 0:
            return None
        current = 10 * math.log10(energy / counted)
        gain = 10 ** ((cls.TARGET_DB - current) / 20)
        clamped = min(cls.MAX_GAIN, max(cls.MIN_GAIN, gain))
        log.debug("%s: %.1f dBFS -> gain %.2f", os.path.basename(path), current, clamped)
        return clamped


# MARK: - Playback


class AudioError(Exception):
    pass


class AudioService:
    def __init__(self):
        ensure_gst()
        self.playing_prayer: Optional[str] = None
        self.previewing = False
        self.duration = 0.0
        self.last_error: Optional[str] = None
        self.on_finish: Optional[Callable[[str], None]] = None
        self.on_change: Optional[Callable[[], None]] = None
        self._player: Optional[Gst.Element] = None
        self._bus_watch = 0
        self._auto_stop = 0
        self._fade = 0

    @property
    def is_playing(self) -> bool:
        return self.playing_prayer is not None

    @property
    def elapsed(self) -> float:
        if self._player is None:
            return 0.0
        ok, position = self._player.query_position(Gst.Format.TIME)
        return position / Gst.SECOND if ok else 0.0

    @property
    def progress(self) -> float:
        if self.duration <= 0:
            ok, dur = self._player.query_duration(Gst.Format.TIME) if self._player else (False, 0)
            if ok and dur > 0:
                self.duration = dur / Gst.SECOND
            else:
                return 0.0
        return min(1.0, max(0.0, self.elapsed / self.duration))

    def _announce(self) -> None:
        if self.on_change:
            self.on_change()

    @staticmethod
    def resolve(sound: AthanSound) -> str:
        if sound.kind == "chime":
            return Chime.path()
        if sound.kind == "bundled":
            found = AthanLibrary.path(sound.name)
            if not found:
                raise AudioError(f"The bundled sound “{sound.name}” is missing from this build.")
            return found
        if sound.kind == "custom":
            found = sound.custom_file
            if not found or not os.path.isfile(found):
                raise AudioError(f"“{sound.label}” could not be opened. Choose the athan file again in Settings.")
            return found
        raise AudioError("silent")

    def play(self, prayer: str, settings: SettingsData) -> None:
        sound = settings.sound(prayer)
        # Stop first even when the new sound is silent, or a running athan
        # would keep playing underneath a prayer that asked for silence.
        self.stop(notify=False)
        if sound.is_silent:
            if self.on_finish:
                self.on_finish(prayer)
            return
        try:
            path = self.resolve(sound)
            self._start(path, settings.athan_volume)
        except (AudioError, GLib.Error) as error:
            message = str(error) if isinstance(error, AudioError) else f"Could not play the athan: {error.message}"
            log.error("athan playback failed: %s", message)
            # A missing custom file still results in an audible athan rather
            # than silence, and the reason is kept for the settings window.
            if sound.kind == "chime":
                self.last_error = message
                if self.on_finish:
                    self.on_finish(prayer)
                return
            fallback = settings.copy()
            fallback.athan_sound = AthanSound.chime()
            fallback.fajr_athan_sound = None
            self.play(prayer, fallback)
            self.last_error = message
            return
        self.playing_prayer = prayer
        self.last_error = None
        if settings.athan_max_seconds > 0:
            self._auto_stop = GLib.timeout_add_seconds(settings.athan_max_seconds, self._on_auto_stop)
        log.info("playing athan for %s", prayer)
        self._announce()

    def preview(self, sound: AthanSound, volume: float) -> None:
        self.stop(notify=False)
        if sound.is_silent:
            return
        try:
            self._start(self.resolve(sound), volume)
            self.previewing = True
        except (AudioError, GLib.Error) as error:
            self.last_error = str(error)
        self._announce()

    def _start(self, path: str, volume: float) -> None:
        player = Gst.ElementFactory.make("playbin", "athan")
        if player is None:
            raise AudioError("GStreamer's playbin is not available.")
        player.set_property("uri", Gst.filename_to_uri(path))
        player.set_property("volume", min(1.0, volume * Normalizer.gain(path)))
        # No video sink for a video file someone picked by mistake.
        fakesink = Gst.ElementFactory.make("fakesink", None)
        if fakesink is not None:
            player.set_property("video-sink", fakesink)
        bus = player.get_bus()
        bus.add_signal_watch()
        self._bus_watch = bus.connect("message", self._on_message, player)
        if player.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            bus.remove_signal_watch()
            player.set_state(Gst.State.NULL)
            raise AudioError("Could not start playback.")
        self._player = player
        self.duration = 0.0

    def _on_message(self, _bus, message, player) -> None:
        if player is not self._player:
            return
        if message.type == Gst.MessageType.EOS:
            self.stop()
        elif message.type == Gst.MessageType.ERROR:
            error, _debug = message.parse_error()
            self.last_error = error.message
            log.error("playback error: %s", error.message)
            self.stop()

    def _on_auto_stop(self) -> bool:
        self._auto_stop = 0
        self.stop()
        return False

    def stop(self, notify: bool = True) -> None:
        """Stop, fading out briefly so it does not cut off harshly."""
        if self._auto_stop:
            GLib.source_remove(self._auto_stop)
            self._auto_stop = 0
        finished = self.playing_prayer
        self.playing_prayer = None
        self.previewing = False
        self.duration = 0.0
        player, self._player = self._player, None
        if player is not None:
            self._fade_out(player)
        self._announce()
        if notify and finished and self.on_finish:
            self.on_finish(finished)

    def _fade_out(self, player: Gst.Element) -> None:
        start = player.get_property("volume")
        steps = 7

        def step(i=[0]):
            i[0] += 1
            if i[0] >= steps:
                bus = player.get_bus()
                bus.remove_signal_watch()
                player.set_state(Gst.State.NULL)
                return False
            player.set_property("volume", start * (1 - i[0] / steps))
            return True

        GLib.timeout_add(50, step)
