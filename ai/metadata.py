"""
Pulls where and when a video/photo was taken out of the file's own metadata.

Videos (MP4/MOV) keep GPS as an ISO 6709 string like "+37.7858-122.4064/",
under 'location' on Android or 'com.apple.quicktime.location.ISO6709' on
iPhone, plus a creation time. Photos have the usual EXIF GPSInfo and
DateTimeOriginal (newer phones also add a time zone offset).

This is the best location we can get since it's where the footage was
actually shot, not where the person was when they uploaded it. Sadly a lot
of files don't have it, WhatsApp, TikTok and screen recordings all strip it.
In that case the app falls back to the phone's GPS at upload, then whatever
the user typed in.

Returns something like
    {"latitude": -26.0045, "longitude": 28.1271, "gps_source": "file",
     "capture_time": "2026-10-11T14:05:31+02:00", "time_source": "file"}
with Nones for anything missing. Times with no zone are assumed to be SAST.
"""

import re
import subprocess
from datetime import datetime, timedelta, timezone
from pathlib import Path

LOCAL_TZ = timezone(timedelta(hours=2), "SAST")     # SA doesn't do daylight saving

VIDEO_GPS_TAGS = ("com.apple.quicktime.location.ISO6709", "location", "location-eng")
VIDEO_TIME_TAGS = ("com.apple.quicktime.creationdate", "creation_time", "date")

# e.g. "+37.7858-122.4064+010.000/" (the altitude part is optional)
_ISO6709 = re.compile(r"^\s*([+-]\d+(?:\.\d+)?)([+-]\d+(?:\.\d+)?)")


def empty():
    return {"latitude": None, "longitude": None, "gps_source": None,
            "capture_time": None, "time_source": None}


def parse_iso6709(text):
    """'+37.7858-122.4064/' -> (37.7858, -122.4064)"""
    match = _ISO6709.match(text or "")
    if not match:
        return None
    lat, lon = float(match.group(1)), float(match.group(2))
    if not (-90 <= lat <= 90 and -180 <= lon <= 180) or (lat == 0 and lon == 0):
        return None                      # phones write 0,0 when they had no fix
    return round(lat, 6), round(lon, 6)


def parse_time(text, assume=LOCAL_TZ):
    """Parse the various date formats phones write. Returns an aware
    datetime or None. Handles ISO with Z or +0200, and EXIF's
    '2026:10:11 14:05:31'."""
    if not text:
        return None
    text = str(text).strip().replace("\x00", "")
    if re.match(r"^\d{4}:\d{2}:\d{2} ", text):             # EXIF uses colons in the date
        text = text.replace(":", "-", 2)
    text = text.replace("Z", "+00:00")
    text = re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", text)  # +0200 -> +02:00
    try:
        t = datetime.fromisoformat(text)
    except ValueError:
        return None
    if t.year < 2000:                    # 1904/1970 means the camera clock was never set
        return None
    return t if t.tzinfo else t.replace(tzinfo=assume)


def _ffmpeg_tags(path):
    """File-level metadata tags, keys lower-cased."""
    try:
        import imageio_ffmpeg
        exe = imageio_ffmpeg.get_ffmpeg_exe()
    except Exception:
        return {}
    # Running `ffmpeg -i file` with no output just prints info and exits.
    # The file-level tags are the lines indented by exactly 4 spaces, before
    # the stream list. We can't use -f ffmetadata because it leaves out
    # creation_time.
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
            key, value = line.split(": ", 1)     # long keys don't get padded
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
        # creation_time is UTC, Apple's creationdate includes the phone's zone
        t = parse_time(tags.get(key.lower()), assume=timezone.utc)
        if t:
            info.update(capture_time=t.astimezone(LOCAL_TZ).isoformat(), time_source="file")
            break
    return info


def _gps_degrees(values, ref):
    """EXIF degrees/minutes/seconds plus N/S/E/W -> signed decimal degrees."""
    d, m, s = (float(v) for v in values)
    value = d + m / 60 + s / 3600
    return -value if str(ref).upper() in ("S", "W") else value


def photo_metadata(path):
    info = empty()
    try:
        from PIL import Image
        try:
            import pillow_heif
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
    taken = details.get(36867) or details.get(36868) or exif.get(306)  # DateTimeOriginal, then Digitized, then DateTime
    offset = details.get(36881) or details.get(36882)                  # OffsetTimeOriginal / Digitized
    t = parse_time(f"{taken}{offset}" if taken and offset else taken)
    if t:
        info.update(capture_time=t.astimezone(LOCAL_TZ).isoformat(), time_source="file")
    return info


def file_metadata(path, is_image=None):
    """GPS and capture time for one file. See the module docstring."""
    path = Path(path)
    if is_image is None:
        from detector import IMAGE_TYPES
        is_image = path.suffix.lower() in IMAGE_TYPES
    try:
        return photo_metadata(path) if is_image else video_metadata(path)
    except Exception:                         # metadata is a nice-to-have, never fail the run over it
        return empty()
