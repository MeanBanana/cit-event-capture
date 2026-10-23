"""
Command-line entry point. Runs the detector over one submission, which is
1-5 videos/photos that belong together (say, one witness's clips of the same
robbery).

    python main.py clip1.mp4 clip2.mp4 photo1.jpg

Each run gets its own numbered folder under crops/ with a results.json and a
subfolder of PNG crops per file. The latest results.json is also copied to
output_detections.json for convenience.

Heads up: track numbers restart per file, so Person #7 in clip1 and
Person #7 in clip2 aren't necessarily the same person.
"""

import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

# The face finder makes OpenCV spam a harmless "Targets are not supported"
# warning. This has to be set before cv2 gets imported.
os.environ.setdefault("OPENCV_LOG_LEVEL", "ERROR")

from detector import IMAGE_TYPES, ArgusDetector
from metadata import file_metadata
from clothing import clothing_word

try:
    from audio import AudioAnalyser
except ImportError as error:
    AudioAnalyser, _AUDIO_ERROR = None, error

MAX_FILES = 5
CROPS = Path("crops")


# --- submission folders

def next_submission_folder(root=CROPS):
    """Make the next crops/submission N folder."""
    root.mkdir(exist_ok=True)
    numbers = [int(m.group(1)) for d in root.iterdir()
               if d.is_dir() and (m := re.fullmatch(r"submission (\d+)", d.name))]
    number = max(numbers, default=0) + 1
    folder = root / f"submission {number}"
    folder.mkdir()
    return number, folder


def file_folder_name(index, path):
    """e.g. '1_clip1': position in the submission plus a filesystem-safe name."""
    stem = re.sub(r"[^A-Za-z0-9_-]+", "_", Path(path).stem).strip("_") or "file"
    return f"{index}_{stem}"


# --- sound

_audio = None


def analyse_sound(video_path):
    """Look for gunfire/explosions in the audio. Never raises, a failure here
    shouldn't take the rest of the run down with it."""
    global _audio
    if AudioAnalyser is None:
        print(f"Sound analysis not available ({_AUDIO_ERROR}). "
              "Run: pip install -r requirements.txt")
        return {"audio_available": False, "audio_events": []}
    try:
        _audio = _audio or AudioAnalyser()     # only load the model once
        return _audio.analyse(video_path)
    except Exception as error:
        print(f"Sound analysis failed ({error}).")
        return {"audio_available": False, "audio_events": []}


def describe_sound(e):
    """One printable line for an audio event."""
    when = f"{e['start_seconds']}-{e['end_seconds']} s"
    flags = [f"could be {w}" for w, key in (("fireworks", "could_be_fireworks"),
                                             ("an explosion", "could_be_explosion"),
                                             ("gun handling", "could_be_handling"))
             if e.get(key)]
    extra = f" [{', '.join(flags)}]" if flags else ""
    if e["event_type"] == "explosion":
        return f"{when}: explosion ({round(e['confidence'] * 100)}%){extra}"
    mode = {"automatic": "AUTOMATIC", "semi_automatic_or_single_shots": "semi-automatic",
            "single_shot": "single shot", "unclear": "unclear"}[e["fire_mode"]]
    return (f"{when}: gunfire ({round(e['confidence'] * 100)}% sure) - {mode}: "
            f"{e['fire_mode_note']}{extra}")


# --- one file

def analyse_file(detector, source, crops_dir):
    """Run everything on a single video or photo and return its results."""
    is_image = source.suffix.lower() in IMAGE_TYPES
    if is_image:
        objects = detector.process_image(source, crops_dir=str(crops_dir))
        sound = {"audio_available": False, "audio_events": []}
    else:
        objects = detector.process_video(source, crops_dir=str(crops_dir))
        sound = analyse_sound(source)

    # GPS/time from the file's own metadata. Often None, WhatsApp strips it.
    meta = file_metadata(source, is_image=is_image)

    vehicles = [o for o in objects if o["detection_type"] == "vehicle"]
    people = [o for o in objects if o["detection_type"] == "person"]
    weapons = [o for o in objects if o["detection_type"] == "weapon"]

    result = {
        "source_path": str(source),
        "source_type": "image" if is_image else "video",
        "crops_folder": str(crops_dir),
        **meta,
        "total_objects": len(objects),
        "vehicle_count": len(vehicles),
        # person_count is distinct track IDs, which overcounts when someone
        # disappears and comes back. max_people_at_once is the safer number.
        "person_count": len(people),
        "weapon_count": len(weapons),
        **detector.last_run_stats,
        "detections": objects,
        # audio leads, videos only. Someone should still listen to confirm.
        **sound,
    }
    print_file_summary(result, vehicles, people, weapons, is_image)
    return result


def print_file_summary(result, vehicles, people, weapons, is_image):
    if result.get("latitude") is not None:
        print(f"Filmed at GPS {result['latitude']}, {result['longitude']}"
              + (f" on {result['capture_time']}" if result.get("capture_time") else ""))
    elif result.get("capture_time"):
        print(f"Filmed on {result['capture_time']} (no GPS in the file)")
    else:
        print("No GPS or recording time in the file (stripped by WhatsApp / TikTok?)")
    print(f"Found {len(vehicles)} vehicle(s), {len(people)} person(s) "
          f"and {len(weapons)} weapon(s).")
    for v in vehicles:
        # % = how much of the car's evidence agreed. "unsure: Opel?" means
        # we had a best guess but not enough agreement to commit to it.
        def describe(answer, share, top3, what):
            if answer:
                return f"{answer} ({round(share * 100)}%)"
            if top3:
                return f"unsure: {next(iter(top3))}?"
            return f"{what} unknown"
        make = (describe(v["make"], v["make_confidence"], v["make_top3"], "make")
                if v.get("make_views", 1) else "make: too far")
        colour = describe(v["colour"], v["colour_confidence"], v["colour_top3"], "colour")
        if v.get("plate"):
            plate = f"plate {v['plate']} ({round(v['plate_confidence'] * 100)}%, {v['plate_reads']} reads)"
        elif v.get("plate_top3"):
            plate = f"plate unsure: {next(iter(v['plate_top3']))}?"
        else:
            plate = "no readable plate"
        seen = "" if is_image else f"seen in {v['frames_seen']} frames"
        print(f"  Vehicle #{v['track_id']:<3} {v['class_name']:<10} "
              f"{make:<20} {colour:<15} {plate:<34} {seen}")

    if result.get("max_people_at_once"):
        if is_image:
            print(f"People in the photo: {result['max_people_at_once']}")
        else:
            print(f"Most people visible at once: {result['max_people_at_once']} "
                  f"(at {result['max_people_time_seconds']} s)")
    for p in people:
        clothing = " / ".join(
            f"{part} {clothing_word(p[key])}" for part, key in
            (("top", "upper_clothing"), ("bottom", "lower_clothing")))
        face = (f"face visible ({p['face_size_px']} px) - picture saved"
                if p["face_visible"] else
                f"face not clear enough (biggest {p['face_size_px']} px)" if p["face_size_px"]
                else "no face seen")
        print(f"  Person  #{p['track_id']:<3} {clothing:<32} {face}")

    if not result.get("weapon_detection"):
        print("Weapons: not checked (weapon model not available)")
    for w in weapons:
        kind = (f"{w['class_name']} ({round(w['weapon_confidence'] * 100)}%)"
                if w["class_name"] else f"unsure: {next(iter(w['weapon_top3']))}?")
        held = (f"with person #{w['held_by_person']}" if w["held_by_person"] is not None
                else "not with a tracked person")
        when = ("" if is_image else
                f"seen {w['first_seen_seconds']}-{w['last_seen_seconds']} s")
        print(f"  Weapon  #{w['track_id']:<3} {kind:<22} {held:<26} {when}")

    if not is_image:
        if not result["audio_available"]:
            print("Sound: none (the video has no sound, or it couldn't be read)")
        elif not result["audio_events"]:
            print("Sound: no gunfire or explosions heard")
        for e in result["audio_events"]:
            print(f"  Heard {describe_sound(e)}")


# --- the whole submission

def analyse_submission(detector, files, folder, number):
    """Run every file in the submission and write results.json.
    backend/worker.py calls this too, so be careful changing what it returns."""
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    results = []
    for index, source in enumerate(files, start=1):
        source = Path(source)
        print(f"\n=== File {index}/{len(files)}: {source.name} ===")
        file_crops = folder / file_folder_name(index, source)
        try:
            results.append(analyse_file(detector, source, file_crops))
        except Exception as error:             # one broken file shouldn't sink the rest
            print(f"Could not process {source.name}: {error}")
            results.append({"source_path": str(source), "error": str(error)})

    ok = [r for r in results if "error" not in r]
    # Location = first file that has GPS, time = earliest recording. The case
    # matcher uses these to suggest a case. If the files have neither, the
    # app falls back to the phone's GPS at upload time.
    with_gps = [r for r in ok if r.get("latitude") is not None]
    times = sorted(r["capture_time"] for r in ok if r.get("capture_time"))
    submission = {
        "submission": number,
        "processed_at": datetime.now().isoformat(),
        "model_version": detector.model_version,
        "file_count": len(files),
        "location": ({"latitude": with_gps[0]["latitude"],
                      "longitude": with_gps[0]["longitude"], "source": "file"}
                     if with_gps else None),
        "capture_time": times[0] if times else None,
        # Note these just add up per file, so a car seen in two clips counts twice
        "totals": {
            "vehicles": sum(r["vehicle_count"] for r in ok),
            "people": sum(r["person_count"] for r in ok),
            "weapons": sum(r["weapon_count"] for r in ok),
            "audio_events": sum(len(r["audio_events"]) for r in ok),
        },
        "files": results,
    }
    with open(folder / "results.json", "w", encoding="utf-8") as f:
        json.dump(submission, f, indent=2)
    return submission


def submission_summary(submission):
    """Short plain-English summary for the app, capped at 600 chars. Something
    like "2 files. 3 people (most at once: 2), 1 vehicle: white Toyota..." """
    ok = [f for f in submission["files"] if "error" not in f]
    if not ok:
        return "The AI could not analyse these files."
    parts = []
    people = sum(f["person_count"] for f in ok)
    most = max((f.get("max_people_at_once") or 0) for f in ok)
    if people:
        parts.append(plural(people, "person", "people")
                     + (f" (most at once: {most})" if most and most < people else ""))
    vehicles = [d for f in ok for d in f["detections"] if d["detection_type"] == "vehicle"]
    if vehicles:
        described = []
        for v in vehicles[:3]:
            look = " ".join(x for x in (v.get("colour"), v.get("make"), v.get("class_name")) if x)
            described.append(look + (f", plate {v['plate']}" if v.get("plate") else ""))
        parts.append(plural(len(vehicles), "vehicle") + ": " + "; ".join(described)
                     + ("; ..." if len(vehicles) > 3 else ""))
    weapons = [d for f in ok for d in f["detections"] if d["detection_type"] == "weapon"]
    if weapons:
        kinds = {}
        for w in weapons:
            kind = (w.get("class_name") or "unclear weapon").replace("_", " ")
            kinds[kind] = kinds.get(kind, 0) + 1
        held = sum(1 for w in weapons if w.get("held_by_person") is not None)
        parts.append(", ".join(plural(n, k) for k, n in kinds.items())
                     + (f" ({held} held by a person)" if held else ""))
    events = [e for f in ok for e in f.get("audio_events", [])]
    gunfire = [e for e in events if e["event_type"] == "gunfire"]
    if gunfire:
        modes = sorted({e["fire_mode"].replace("_", " ") for e in gunfire})
        parts.append("gunfire heard (" + ", ".join(modes) + ")")
    if any(e["event_type"] == "explosion" for e in events):
        parts.append("explosion heard")
    text = (f"{plural(len(submission['files']), 'file')}. "
            + (". ".join(p[0].upper() + p[1:] for p in parts) + "." if parts
               else "No vehicles, people or weapons found."))
    return (text + " AI-generated - check against the footage.")[:600]


def plural(n, one, many=None):
    return f"{n} {one if n == 1 else (many or one + 's')}"


def main():
    files = [Path(a) for a in sys.argv[1:]]
    if not files:
        print("Usage: python main.py file1 [file2 ... file5]   "
              "(videos and/or photos; all files together are ONE submission)")
        return
    if len(files) > MAX_FILES:
        print(f"Too many files: {len(files)}. A submission can have at most {MAX_FILES}.")
        return
    missing = [str(f) for f in files if not f.is_file()]
    if missing:
        print("File(s) not found: " + ", ".join(missing))
        return

    number, folder = next_submission_folder()
    print(f"Submission {number}: {len(files)} file(s) -> {folder}")
    detector = ArgusDetector()                 # load models once, reuse for every file
    submission = analyse_submission(detector, files, folder, number)
    with open("output_detections.json", "w", encoding="utf-8") as f:
        json.dump(submission, f, indent=2)

    ok = [r for r in submission["files"] if "error" not in r]
    t = submission["totals"]
    print(f"\n=== Submission {number} done: {len(ok)}/{len(files)} file(s) processed - "
          f"{t['vehicles']} vehicle(s), {t['people']} person(s), {t['weapons']} weapon(s), "
          f"{t['audio_events']} gunfire/explosion sound(s) ===")
    print(f"Summary: {submission_summary(submission)}")
    if t["weapons"] or t["audio_events"]:
        print("Reminder: CIT guards are armed too - a weapon or shot is a lead "
              "for the investigator, not proof of who the robber is.")
    print(f"Results: {folder / 'results.json'} (copy in output_detections.json); "
          f"pictures in {folder}")


if __name__ == "__main__":
    main()
