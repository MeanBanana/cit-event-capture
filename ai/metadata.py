"""
metadata.py - WHERE and WHEN a video or photo was taken, from the file itself.

Phones write this into the file when it is recorded:
  * videos (MP4 / MOV): GPS as an ISO 6709 string ("+37.7858-122.4064/"),
    under 'location' (Android) or 'com.apple.quicktime.location.ISO6709'
    (iPhone), and the recording time ('creation_time', UTC, or
    'com.apple.quicktime.creationdate' with the phone's time zone)
  * photos (JPEG / HEIC / ...): EXIF GPSInfo and DateTimeOriginal (+ the
    time zone in OffsetTimeOriginal on newer phones)

The file's own GPS is the best location there is: it is where the footage
was FILMED, not where the citizen was when they uploaded it. Many files have
none, though: WhatsApp, TikTok and screen recordings strip it. Then the app
falls back to the phone's GPS at upload, then the typed location.

    file_metadata("clip.mp4") ->
      {"latitude": -26.0045, "longitude": 28.1271, "gps_source": "file",
       "capture_time": "2026-10-11T14:05:31+02:00", "time_source": "file"}
    (all None when the file carries nothing)

Times without a time zone (older phones' EXIF) are taken as South African
time (LOCAL_TZ).
"""

import re
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

LOCAL_TZ = timezone(timedelta(hours=2), "SAST")     # Africa/Johannesburg, no DST

VIDEO_GPS_TAGS = ("com.apple.quicktime.location.ISO6709", "location", "location-eng")
VIDEO_TIME_TAGS = ("com.apple.quicktime.creationdate", "creation_time", "date")

# "+37.7858-122.4064+010.000/"  (latitude, longitude, optional altitude)
_ISO6709 = re.compile(r"^\s*([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)")


def empty():
    return {"latitude": None, "longitude": None, "gps_source": None,
            "capture_time": None, "time_source": None}


def parse_iso6709(text):
    """'+37.7858-122.4064/' -> (37.7858, -122.4064), or None."""
    match = _ISO6709.match(text or "")
    if not match:
        return None
    lat, lon = float(match.group(1)), float(match.group(2))
    if not (-90 <= lat <= 90 and -180 <= lon <= 180) or (lat == 0 and lon == 0):
        return None                      # 0,0 = a phone that had no fix
    return round(lat, 6), round(lon, 6)


def parse_time(text, assume=LOCAL_TZ):
    """Most date formats phones write -> aware datetime, or None.
    '2026-10-11T12:05:31.000000Z', '2026-10-11T14:05:31+0200',
    '2026:10:11 14:05:31' (EXIF) ..."""
    if not text:
        return None
    text = str(text).strip().replace("\x00", "")
    if re.match(r"^\d{4}:\d{2}:\d{2} ", text):             # EXIF uses colons
        text = text.replace(":", "-", 2)
    text = text.replace("Z", "+00:00")
    text = re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", text)  # +0200 -> +02:00
    try:
        t = datetime.fromisoformat(text)
    except ValueError:
        return None
    if t.year < 2000:                    # 1904/1970 = camera clock never set
        return None
    return t if t.tzinfo else t.replace(tzinfo=assume)


def _ffmpeg_tags(path):
    """The file's global metadata tags as a dict (lower-case keys)."""
    try:
        import imageio_ffmpeg
        exe = imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return {}
    # 'ffmpeg -i file' (no output) prints the file's details and exits; the
    # file-level tags are the "    key : value" lines (4-space indent) before
    # the streams. (creation_time is only shown there, not by -f ffmetadata.)
    try:
        out = subprocess.run([exe, "-hide_banner", "-i", str(path)],
                             capture_output=True, text=True, timeout=30,
                             encoding="utf-8", errors="replace").stderr
    except (OSError, subprocess.TimeoutExpired):
        return {}
    tags = {}
    for line in out.splitlines():
        if line.lstrip().startswith(("Duration:", "Stream #")):
            break
        if line.startswith("    ") and not line.startswith("     ") and ": " in line:
            key, value = line.split(": ", 1)     # long keys have no padding
            tags.setdefault(key.strip().lower(), value.strip())
    return tags


def video_metadata(path):
    info = empty()
    tags = _ffmpeg_tags(path)
    for key in VIDEO_GPS_TAGS:
        gps = parse_iso6709(tags.get(key.lower()))
        if gps:
            info.update(latitude=gps[0], longitude=gps[1], gps_source="file")
            break
    for key in VIDEO_TIME_TAGS:
        # creation_time is UTC; Apple's creationdate carries the phone's zone
        t = parse_time(tags.get(key.lower()), assume=timezone.utc)
        if t:
            info.update(capture_time=t.astimezone(LOCAL_TZ).isoformat(), time_source="file")
            break
    return info


def _gps_degrees(values, ref):
    """EXIF (degrees, minutes, seconds) + 'N'/'S'/'E'/'W' -> signed float."""
    d, m, s = (float(v) for v in values)
    value = d + m / 60 + s / 3600
    return -value if str(ref).upper() in ("S", "W") else value


def photo_metadata(path):
    info = empty()
    try:
        from PIL import Image
        try:
            import pillow_heif                # iPhone HEIC
            pillow_heif.register_heif_opener()
        except ImportError:
            pass
        with Image.open(path) as image:
            exif = image.getexif()
    except Exception:
        return info
    if not exif:
        return info

    gps = exif.get_ifd(0x8825)               # GPSInfo
    try:
        if gps and 2 in gps and 4 in gps:
            lat = _gps_degrees(gps[2], gps.get(1, "N"))
            lon = _gps_degrees(gps[4], gps.get(3, "E"))
            if -90 <= lat <= 90 and -180 <= lon <= 180 and not (lat == 0 and lon == 0):
                info.update(latitude=round(lat, 6), longitude=round(lon, 6), gps_source="file")
    except (TypeError, ValueError, ZeroDivisionError):
        pass

    details = exif.get_ifd(0x8769)           # Exif sub-IFD
    taken = details.get(36867) or details.get(36868) or exif.get(306)  # Original / Digitized / DateTime
    offset = details.get(36881) or details.get(36882)                  # OffsetTimeOriginal
    t = parse_time(f"{taken}{offset}" if taken and offset else taken)
    if t:
        info.update(capture_time=t.astimezone(LOCAL_TZ).isoformat(), time_source="file")
    return info


def file_metadata(path, is_image=None):
    """GPS + capture time of one video or photo (see the top of this file)."""
    path = Path(path)
    if is_image is None:
        from detector import IMAGE_TYPES
        is_image = path.suffix.lower() in IMAGE_TYPES
    try:
        return photo_metadata(path) if is_image else video_metadata(path)
    except Exception:                         # never stop the run over metadata
        return empty()
