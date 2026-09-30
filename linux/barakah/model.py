"""Barakah's plain values — the Linux mirror of Sources/Barakah/Model.

Settings are read and written in exactly the JSON shape the Swift app's
Codable conformances produce, so a settings.json copied from a Mac works here
unchanged, and the other way round. Keys this build does not use (AppleScript,
for one) are kept and written back rather than dropped.
"""

from __future__ import annotations

import base64
import copy
import os
from dataclasses import dataclass, field
from typing import Any, Optional

from . import adhan

# MARK: - Prayers

PRAYER_KINDS = ("fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha")
PRAYERS = tuple(k for k in PRAYER_KINDS if k != "sunrise")

NAMES = {
    "fajr": "Fajr", "sunrise": "Sunrise", "dhuhr": "Dhuhr",
    "asr": "Asr", "maghrib": "Maghrib", "isha": "Isha",
}
ARABIC_NAMES = {
    "fajr": "الفجر", "sunrise": "الشروق", "dhuhr": "الظهر",
    "asr": "العصر", "maghrib": "المغرب", "isha": "العشاء",
}


def is_prayer(kind: str) -> bool:
    return kind != "sunrise"


# MARK: - Iqama

@dataclass(frozen=True)
class IqamaRule:
    """`none`, `offset` (minutes after the athan) or `fixed` (a wall-clock time)."""
    kind: str = "none"
    minutes: int = 0
    hour: int = 0
    minute: int = 0

    @classmethod
    def off(cls) -> "IqamaRule":
        return cls("none")

    @classmethod
    def offset(cls, minutes: int) -> "IqamaRule":
        return cls("offset", minutes=minutes)

    @classmethod
    def fixed(cls, hour: int, minute: int) -> "IqamaRule":
        return cls("fixed", hour=hour, minute=minute)

    @property
    def is_enabled(self) -> bool:
        return self.kind != "none"

    def to_json(self) -> dict:
        if self.kind == "offset":
            return {"offset": {"minutes": self.minutes}}
        if self.kind == "fixed":
            return {"fixed": {"hour": self.hour, "minute": self.minute}}
        return {"none": {}}

    @classmethod
    def from_json(cls, value: Any, default: "IqamaRule") -> "IqamaRule":
        if not isinstance(value, dict) or len(value) != 1:
            return default
        (tag, body), = value.items()
        body = body if isinstance(body, dict) else {}
        if tag == "offset":
            return cls.offset(int(body.get("minutes", 10)))
        if tag == "fixed":
            return cls.fixed(int(body.get("hour", 13)), int(body.get("minute", 30)))
        if tag == "none":
            return cls.off()
        return default


DEFAULT_IQAMA = IqamaRule.offset(10)


# MARK: - Media

MEDIA_PAUSE_MODES = ("off", "pause", "pauseAndMute")
MEDIA_PAUSE_LABELS = {
    "off": "Do nothing",
    "pause": "Pause playback",
    "pauseAndMute": "Pause and mute other audio",
}


def pauses_players(mode: str) -> bool:
    return mode != "off"


def mutes_output(mode: str) -> bool:
    return mode == "pauseAndMute"


@dataclass(frozen=True)
class MediaResumeMode:
    """`never`, `afterAthan`, `afterMinutes` or `afterIqama`."""
    kind: str = "never"
    minutes: int = 0

    @property
    def label(self) -> str:
        return {
            "never": "Don't resume",
            "afterAthan": "When the athan ends",
            "afterMinutes": f"{self.minutes} minutes after the athan",
            "afterIqama": "At iqama time",
        }.get(self.kind, "Don't resume")

    def to_json(self) -> dict:
        if self.kind == "afterMinutes":
            return {"afterMinutes": {"_0": self.minutes}}
        return {self.kind: {}}

    @classmethod
    def from_json(cls, value: Any) -> "MediaResumeMode":
        if not isinstance(value, dict) or len(value) != 1:
            return cls()
        (tag, body), = value.items()
        if tag == "afterMinutes":
            body = body if isinstance(body, dict) else {}
            return cls("afterMinutes", int(body.get("_0", 5)))
        if tag in ("never", "afterAthan", "afterIqama"):
            return cls(tag)
        return cls()


# MARK: - Athan sound

DEFAULT_BUNDLED_NAME = "Adhan"


@dataclass(frozen=True)
class AthanSound:
    """`chime`, `bundled` (a library name), `custom` (a user file) or `silent`.

    On macOS a custom sound is a security-scoped bookmark. Linux has no such
    thing, so here the "bookmark" is simply the file's path, base64-encoded to
    keep the JSON shape identical. A Mac bookmark read on Linux will not
    resolve, and playback falls back to the chime exactly as it does on a Mac
    whose custom file has moved.
    """
    kind: str = "bundled"
    name: str = DEFAULT_BUNDLED_NAME
    bookmark: bytes = b""

    @classmethod
    def chime(cls) -> "AthanSound":
        return cls("chime", "")

    @classmethod
    def silent(cls) -> "AthanSound":
        return cls("silent", "")

    @classmethod
    def bundled(cls, name: str) -> "AthanSound":
        return cls("bundled", name)

    @classmethod
    def custom_path(cls, path: str) -> "AthanSound":
        stem = os.path.splitext(os.path.basename(path))[0]
        return cls("custom", stem, path.encode("utf-8"))

    @property
    def custom_file(self) -> Optional[str]:
        if self.kind != "custom":
            return None
        try:
            path = self.bookmark.decode("utf-8")
        except UnicodeDecodeError:
            return None
        return path if path.startswith("/") else None

    @property
    def is_silent(self) -> bool:
        return self.kind == "silent"

    @property
    def label(self) -> str:
        if self.kind == "chime":
            return "Chime (built in)"
        if self.kind == "silent":
            return "Silent"
        if self.kind == "bundled":
            return bundled_display_name(self.name)
        return self.name

    def to_json(self) -> dict:
        if self.kind == "bundled":
            return {"bundled": {"_0": self.name}}
        if self.kind == "custom":
            return {"custom": {"bookmark": base64.b64encode(self.bookmark).decode("ascii"),
                               "displayName": self.name}}
        return {self.kind: {}}

    @classmethod
    def from_json(cls, value: Any) -> Optional["AthanSound"]:
        if not isinstance(value, dict) or len(value) != 1:
            return None
        (tag, body), = value.items()
        body = body if isinstance(body, dict) else {}
        if tag == "bundled":
            return cls.bundled(str(body.get("_0", DEFAULT_BUNDLED_NAME)))
        if tag == "custom":
            try:
                raw = base64.b64decode(body.get("bookmark", ""))
            except (ValueError, TypeError):
                raw = b""
            return cls("custom", str(body.get("displayName", "Custom")), raw)
        if tag in ("chime", "silent"):
            return cls(tag, "")
        return None


def bundled_display_name(resource: str) -> str:
    text = resource.replace("-", " ").replace("_", " ")
    # Foundation's `capitalized`: first letter of each word upper, rest lower.
    return " ".join(w[:1].upper() + w[1:].lower() for w in text.split(" "))


# MARK: - Place

@dataclass(frozen=True)
class PlaceSetting:
    name: str
    latitude: float
    longitude: float
    # IANA identifier; empty means "use the system timezone".
    time_zone_identifier: str = ""

    def to_json(self) -> dict:
        return {"name": self.name, "latitude": self.latitude, "longitude": self.longitude,
                "timeZoneIdentifier": self.time_zone_identifier}

    @classmethod
    def from_json(cls, value: Any) -> Optional["PlaceSetting"]:
        if not isinstance(value, dict):
            return None
        try:
            return cls(str(value.get("name", "")), float(value["latitude"]),
                       float(value["longitude"]), str(value.get("timeZoneIdentifier", "")))
        except (KeyError, TypeError, ValueError):
            return None

    @property
    def short_coordinate_description(self) -> str:
        return "%.3f°%s, %.3f°%s" % (
            abs(self.latitude), "N" if self.latitude >= 0 else "S",
            abs(self.longitude), "E" if self.longitude >= 0 else "W")


MAKKAH = PlaceSetting("Makkah", 21.422510, 39.826168, "Asia/Riyadh")


# MARK: - Per-prayer configuration

@dataclass
class PrayerConfig:
    athan_enabled: bool = True
    media_mode: str = "pause"
    iqama_rule: IqamaRule = DEFAULT_IQAMA
    iqama_reminder_minutes: int = 5
    iqama_alert_enabled: bool = False
    athan_adjustment_minutes: int = 0

    @classmethod
    def sunrise_default(cls) -> "PrayerConfig":
        return cls(False, "off", IqamaRule.off(), 0, False, 0)

    @classmethod
    def default_for(cls, kind: str) -> "PrayerConfig":
        return cls() if is_prayer(kind) else cls.sunrise_default()

    def to_json(self) -> dict:
        return {
            "athanAdjustmentMinutes": self.athan_adjustment_minutes,
            "athanEnabled": self.athan_enabled,
            "iqamaAlertEnabled": self.iqama_alert_enabled,
            "iqamaReminderMinutes": self.iqama_reminder_minutes,
            "iqamaRule": self.iqama_rule.to_json(),
            "mediaMode": self.media_mode,
        }

    @classmethod
    def from_json(cls, value: Any, kind: str) -> "PrayerConfig":
        base = cls.default_for(kind)
        if not isinstance(value, dict):
            return base
        mode = value.get("mediaMode", base.media_mode)
        return cls(
            athan_enabled=bool(value.get("athanEnabled", base.athan_enabled)),
            media_mode=mode if mode in MEDIA_PAUSE_MODES else base.media_mode,
            iqama_rule=IqamaRule.from_json(value.get("iqamaRule"), base.iqama_rule),
            iqama_reminder_minutes=int(value.get("iqamaReminderMinutes", base.iqama_reminder_minutes)),
            iqama_alert_enabled=bool(value.get("iqamaAlertEnabled", base.iqama_alert_enabled)),
            athan_adjustment_minutes=int(value.get("athanAdjustmentMinutes", base.athan_adjustment_minutes)),
        )


# MARK: - Labels

METHOD_LABELS = {
    "muslimWorldLeague": "Muslim World League",
    "egyptian": "Egyptian General Authority",
    "karachi": "University of Islamic Sciences, Karachi",
    "ummAlQura": "Umm al-Qura, Makkah",
    "dubai": "Dubai",
    "moonsightingCommittee": "Moonsighting Committee",
    "northAmerica": "ISNA (North America)",
    "kuwait": "Kuwait",
    "qatar": "Qatar",
    "singapore": "Singapore",
    "tehran": "Tehran",
    "turkey": "Diyanet (Turkey)",
    "other": "Custom",
}
SELECTABLE_METHODS = (
    "muslimWorldLeague", "northAmerica", "egyptian", "karachi", "ummAlQura",
    "dubai", "qatar", "kuwait", "singapore", "turkey", "tehran", "moonsightingCommittee",
)
MADHAB_LABELS = {adhan.SHAFI: "Shafi'i, Maliki, Hanbali", adhan.HANAFI: "Hanafi"}
MADHAB_DESCRIPTIONS = {
    adhan.SHAFI: "Asr when a shadow equals an object's length",
    adhan.HANAFI: "Asr when a shadow equals twice an object's length",
}
HIGH_LATITUDE_LABELS = {
    "middleOfTheNight": "Middle of the night",
    "seventhOfTheNight": "One seventh of the night",
    "twilightAngle": "Twilight angle",
}
MENU_BAR_STYLES = ("nextTime", "countdown", "nextName", "iconOnly")
MENU_BAR_STYLE_LABELS = {
    "countdown": "Countdown to next prayer",
    "nextTime": "Next prayer time",
    "nextName": "Next prayer name",
    "iconOnly": "Icon only",
}


# MARK: - Settings

_FIELDS = {
    # json key: (attribute, kind)
    "locationMode": ("location_mode", "str"),
    "calculationMethod": ("calculation_method", "str"),
    "madhab": ("madhab", "int"),
    "customFajrAngle": ("custom_fajr_angle", "optfloat"),
    "customIshaAngle": ("custom_isha_angle", "optfloat"),
    "jumuahEnabled": ("jumuah_enabled", "bool"),
    "jumuahReminderMinutes": ("jumuah_reminder_minutes", "int"),
    "athanVolume": ("athan_volume", "float"),
    "athanMaxSeconds": ("athan_max_seconds", "int"),
    "showAthanWindow": ("show_athan_window", "bool"),
    "useMediaRemote": ("use_media_remote", "bool"),
    "useAppleScript": ("use_apple_script", "bool"),
    "notifyAtAthan": ("notify_at_athan", "bool"),
    "notificationSoundEnabled": ("notification_sound_enabled", "bool"),
    "menuBarStyle": ("menu_bar_style", "str"),
    "use24HourClock": ("use_24_hour_clock", "bool"),
    "showHijriDate": ("show_hijri_date", "bool"),
    "showSunrise": ("show_sunrise", "bool"),
    "launchAtLogin": ("launch_at_login", "bool"),
    "hasCompletedOnboarding": ("has_completed_onboarding", "bool"),
}


@dataclass
class SettingsData:
    # Location
    location_mode: str = "automatic"
    manual_place: PlaceSetting = MAKKAH
    resolved_place: Optional[PlaceSetting] = None
    # Calculation
    calculation_method: str = "muslimWorldLeague"
    madhab: int = adhan.SHAFI
    high_latitude_rule: Optional[str] = None
    custom_fajr_angle: Optional[float] = None
    custom_isha_angle: Optional[float] = None
    # Per prayer
    prayer_configs: dict = field(default_factory=lambda: {
        k: PrayerConfig.default_for(k) for k in PRAYER_KINDS})
    jumuah_enabled: bool = False
    jumuah_iqama_rule: IqamaRule = IqamaRule.fixed(13, 30)
    jumuah_reminder_minutes: int = 15
    # Audio
    athan_sound: AthanSound = AthanSound.bundled(DEFAULT_BUNDLED_NAME)
    fajr_athan_sound: Optional[AthanSound] = None
    athan_volume: float = 0.8
    athan_max_seconds: int = 0
    show_athan_window: bool = True
    # Media. `use_media_remote` is the MPRIS switch on Linux; the AppleScript
    # flag has no Linux meaning and is only carried through.
    resume_mode: MediaResumeMode = MediaResumeMode()
    use_media_remote: bool = True
    use_apple_script: bool = True
    media_excluded_bundle_ids: list = field(default_factory=list)
    # Notifications
    notify_at_athan: bool = True
    notification_sound_enabled: bool = False
    # General
    menu_bar_style: str = "nextTime"
    use_24_hour_clock: bool = False
    show_hijri_date: bool = True
    show_sunrise: bool = True
    launch_at_login: bool = False
    has_completed_onboarding: bool = False
    # Keys written by another build that this one does not model.
    extra: dict = field(default_factory=dict)

    def copy(self) -> "SettingsData":
        return copy.deepcopy(self)

    def config(self, kind: str) -> PrayerConfig:
        return self.prayer_configs.get(kind) or PrayerConfig.default_for(kind)

    @property
    def active_place(self) -> PlaceSetting:
        if self.location_mode == "manual":
            return self.manual_place
        return self.resolved_place or self.manual_place

    @property
    def calculation_parameters(self) -> adhan.CalculationParameters:
        params = adhan.method_params(self.calculation_method)
        params.madhab = self.madhab
        if self.high_latitude_rule is not None:
            params.high_latitude_rule = self.high_latitude_rule
        if self.custom_fajr_angle is not None:
            params.fajr_angle = self.custom_fajr_angle
        if self.custom_isha_angle is not None:
            params.isha_angle = self.custom_isha_angle
            params.isha_interval = 0
        return params

    def effective_iqama_rule(self, kind: str, is_friday: bool) -> IqamaRule:
        if kind == "dhuhr" and is_friday and self.jumuah_enabled:
            return self.jumuah_iqama_rule
        return self.config(kind).iqama_rule

    def effective_reminder_minutes(self, kind: str, is_friday: bool) -> int:
        if kind == "dhuhr" and is_friday and self.jumuah_enabled:
            return self.jumuah_reminder_minutes
        return self.config(kind).iqama_reminder_minutes

    def sound(self, kind: str) -> AthanSound:
        if kind == "fajr" and self.fajr_athan_sound is not None:
            return self.fajr_athan_sound
        return self.athan_sound

    # MARK: JSON

    def to_json(self) -> dict:
        out: dict = dict(self.extra)
        for key, (attr, kind) in _FIELDS.items():
            value = getattr(self, attr)
            if kind == "optfloat" and value is None:
                out.pop(key, None)
                continue
            out[key] = value
        out["manualPlace"] = self.manual_place.to_json()
        if self.resolved_place is not None:
            out["resolvedPlace"] = self.resolved_place.to_json()
        else:
            out.pop("resolvedPlace", None)
        if self.high_latitude_rule is not None:
            out["highLatitudeRule"] = self.high_latitude_rule
        else:
            out.pop("highLatitudeRule", None)
        out["prayerConfigs"] = {k: self.config(k).to_json() for k in PRAYER_KINDS}
        out["jumuahIqamaRule"] = self.jumuah_iqama_rule.to_json()
        out["athanSound"] = self.athan_sound.to_json()
        if self.fajr_athan_sound is not None:
            out["fajrAthanSound"] = self.fajr_athan_sound.to_json()
        else:
            out.pop("fajrAthanSound", None)
        out["resumeMode"] = self.resume_mode.to_json()
        out["mediaExcludedBundleIDs"] = list(self.media_excluded_bundle_ids)
        return out

    @classmethod
    def from_json(cls, data: Any) -> "SettingsData":
        if not isinstance(data, dict):
            raise ValueError("settings must be a JSON object")
        s = cls()
        known = set(_FIELDS) | {
            "manualPlace", "resolvedPlace", "highLatitudeRule", "prayerConfigs",
            "jumuahIqamaRule", "athanSound", "fajrAthanSound", "resumeMode",
            "mediaExcludedBundleIDs",
        }
        s.extra = {k: v for k, v in data.items() if k not in known}
        for key, (attr, kind) in _FIELDS.items():
            if key not in data or data[key] is None:
                continue
            value = data[key]
            if kind == "bool":
                setattr(s, attr, bool(value))
            elif kind == "int":
                setattr(s, attr, int(value))
            elif kind in ("float", "optfloat"):
                setattr(s, attr, float(value))
            else:
                setattr(s, attr, str(value))
        if s.location_mode not in ("automatic", "manual"):
            s.location_mode = "automatic"
        if s.calculation_method not in adhan.METHODS:
            s.calculation_method = "muslimWorldLeague"
        if s.madhab not in (adhan.SHAFI, adhan.HANAFI):
            s.madhab = adhan.SHAFI
        if s.menu_bar_style not in MENU_BAR_STYLES:
            s.menu_bar_style = "nextTime"
        s.manual_place = PlaceSetting.from_json(data.get("manualPlace")) or MAKKAH
        s.resolved_place = PlaceSetting.from_json(data.get("resolvedPlace"))
        rule = data.get("highLatitudeRule")
        s.high_latitude_rule = rule if rule in adhan.HIGH_LATITUDE_RULES else None
        configs = data.get("prayerConfigs") if isinstance(data.get("prayerConfigs"), dict) else {}
        s.prayer_configs = {k: PrayerConfig.from_json(configs.get(k), k) for k in PRAYER_KINDS}
        s.jumuah_iqama_rule = IqamaRule.from_json(data.get("jumuahIqamaRule"), IqamaRule.fixed(13, 30))
        s.athan_sound = AthanSound.from_json(data.get("athanSound")) or AthanSound.bundled(DEFAULT_BUNDLED_NAME)
        s.fajr_athan_sound = AthanSound.from_json(data.get("fajrAthanSound"))
        s.resume_mode = MediaResumeMode.from_json(data.get("resumeMode"))
        excluded = data.get("mediaExcludedBundleIDs")
        s.media_excluded_bundle_ids = [str(x) for x in excluded] if isinstance(excluded, list) else []
        return s
