"""The Hijri date in the Umm al-Qura calendar, through ICU.

Foundation's `Calendar(identifier: .islamicUmmAlQura)` is ICU underneath, so
asking the system's ICU for the same calendar and pattern gives the date and
month spelling the macOS app shows. ICU's C symbols carry a version suffix
on Linux (`udat_open_74`); it is found at load time rather than hard-coded.
"""

from __future__ import annotations

import ctypes
import ctypes.util
import glob
import re
from typing import Optional

_UDAT_PATTERN = -2
_api = None
_tried = False


def _load():
    global _api, _tried
    if _tried:
        return _api
    _tried = True
    candidates = []
    for name in ("icui18n", "icucore"):
        found = ctypes.util.find_library(name)
        if found:
            candidates.append(found)
    candidates += sorted(glob.glob("/usr/lib/*/libicui18n.so.*")) + sorted(glob.glob("/usr/lib/libicui18n.so.*"))
    for path in candidates:
        try:
            lib = ctypes.CDLL(path)
        except OSError:
            continue
        suffixes = [""]
        match = re.search(r"\.so\.(\d+)", path)
        if match:
            suffixes.insert(0, "_" + match.group(1))
        for suffix in suffixes:
            try:
                open_ = getattr(lib, "udat_open" + suffix)
                format_ = getattr(lib, "udat_format" + suffix)
                close = getattr(lib, "udat_close" + suffix)
            except AttributeError:
                continue
            open_.restype = ctypes.c_void_p
            open_.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_char_p,
                              ctypes.c_void_p, ctypes.c_int32, ctypes.c_void_p, ctypes.c_int32,
                              ctypes.POINTER(ctypes.c_int)]
            format_.restype = ctypes.c_int32
            format_.argtypes = [ctypes.c_void_p, ctypes.c_double, ctypes.c_void_p, ctypes.c_int32,
                                ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
            close.restype = None
            close.argtypes = [ctypes.c_void_p]
            _api = (open_, format_, close)
            return _api
    return None


def _uchars(text: str):
    data = text.encode("utf-16-le")
    buf = (ctypes.c_uint16 * (len(data) // 2 + 1))()
    ctypes.memmove(buf, data, len(data))
    return buf, len(data) // 2


def format_date(ts: float, time_zone: str, pattern: str,
                locale: str = "en_US_POSIX@calendar=islamic-umalqura") -> Optional[str]:
    api = _load()
    if api is None:
        return None
    open_, format_, close = api
    status = ctypes.c_int(0)
    tz, tz_len = _uchars(time_zone)
    pat, pat_len = _uchars(pattern)
    fmt = open_(_UDAT_PATTERN, _UDAT_PATTERN, locale.encode("ascii"), tz, tz_len, pat, pat_len,
                ctypes.byref(status))
    if not fmt or status.value > 0:
        return None
    try:
        out = (ctypes.c_uint16 * 128)()
        status = ctypes.c_int(0)
        n = format_(fmt, ts * 1000.0, out, 128, None, ctypes.byref(status))
        if status.value > 0 or n <= 0:
            return None
        return bytes(out)[: n * 2].decode("utf-16-le")
    finally:
        close(fmt)


def hijri_date(ts: float, time_zone: str) -> Optional[str]:
    """"7 Rabiʻ II 1448 AH", or None where ICU is unavailable."""
    text = format_date(ts, time_zone, "d MMMM yyyy")
    return text + " AH" if text else None
