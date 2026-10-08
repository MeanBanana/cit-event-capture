"""
main.py - run the detector on a SUBMISSION: 1 to 5 videos and/or photos that
belong together (e.g. one witness's clips of the same robbery).

Usage:
    python main.py video.mp4
    python main.py clip1.mp4 clip2.mp4 photo1.jpg          (up to 5 files)

Photos: JPEG, PNG, WebP, BMP, TIFF, GIF and iPhone HEIC/HEIF.
Videos: MP4, MOV, AVI, MKV, M4V, 3GP, WebM (and anything else OpenCV opens).

Every run is ONE submission and gets the next number. Results go in:

    crops/
      submission 1/
        results.json              everything found, per file
        1_clip1/                  the PNG pictures from the first file
          vehicle_3.png  plate_3.png  person_7.png  face_7.png  weapon_2.png ...
        2_clip2/
        3_photo1/
      submission 2/
        ...

(output_detections.json next to main.py is a copy of the latest results.json.)

Track numbers (Vehicle #3, Person #7, ...) are per file: Person #7 in clip1
and Person #7 in clip2 are not necessarily the same person.

Printed summary per file, e.g.:

    Vehicle #3  car  Toyota (90%)  white (80%)  plate CA123456 (85%, 9 reads)  seen in 15 frames
    Most people visible at once: 3 (at 4.2 s)
    Person  #7  top black / bottom blue   face visible (52 px) - picture saved
    Weapon  #2  long_gun (88%)  with person #7   seen 12.0-16.4 s
    Heard 14.2-15.1 s: gunfire (94% sure) - AUTOMATIC: 11 bangs 0.085 s apart, evenly spaced ...
"""

import json
import os
import re
import sys
from datetime import datetime
from pathlib import Path

# Hide OpenCV's harmless "Targets are not supported by the new graph engine"
# warning (from the face finder). Must be set before OpenCV is imported.
os.environ.setdefault("OPENCV_LOG_LEVEL", "ERROR")

from detector import IMAGE_TYPES, ArgusDetector

try:
    from audio import AudioAnalyser
except ImportError as error:              # audio.py or a package missing
    AudioAnalyser, _AUDIO_ERROR = None, error

MAX_FILES = 5
CROPS = Path("crops")


# ---------------------------------------------------------------------------
# Submission folders
# ---------------------------------------------------------------------------

def next_submission_folder(root=CROPS):
    """crops/submission N, with N one higher than the highest existing one."""
    root.mkdir(exist_ok=True)
    numbers = [int(m.group(1)) for d in root.iterdir()
               if d.is_dir() and (m := re.fullmatch(r"submission (\d+)", d.name))]
    number = max(numbers, default=0) + 1
    folder = root / f"submission {number}"
    folder.mkdir()
    return number, folder


def file_folder_name(index, path):
    """'1_clip1' - the file's position in the submission + its name (made safe)."""
    stem = re.sub(r"[^A-Za-z0-9_-]+", "_", Path(path).stem).strip("_") or "file"
    return f"{index}_{stem}"


# ---------------------------------------------------------------------------
# Sound
# ---------------------------------------------------------------------------

_audio = None


def analyse_sound(video_path):
    """Gunfire / explosion events in the video's sound (never stops the run)."""
    global _audio
    if AudioAnalyser is None:
        print(f"Sound analysis not available ({_AUDIO_ERROR}). "
              "Run: pip install -r requirements.txt")
        return {"audio_available": False, "audio_events": []}
    try:
        _audio = _audio or AudioAnalyser()     # load the sound model once
        return _audio.analyse(video_path)
    except Exception as error:
        print(f"Sound analysis failed ({error}).")
        return {"audio_available": False, "audio_events": []}


def describe_sound(e):
    """One line for a gunfire / explosion event."""
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


# ---------------------------------------------------------------------------
# One file
# ---------------------------------------------------------------------------

def analyse_file(detector, source, crops_dir):
    """Runs everything on one video/photo. Returns its results (a dict)."""
    is_image = source.suffix.lower() in IMAGE_TYPES
    if is_image:
        objects = detector.process_image(source, crops_dir=str(crops_dir))
        sound = {"audio_available": False, "audio_events": []}
    else:
        objects = detector.process_video(source, crops_dir=str(crops_dir))
        sound = analyse_sound(source)

    vehicles = [o for o in objects if o["detection_type"] == "vehicle"]
    people = [o for o in objects if o["detection_type"] == "person"]
    weapons = [o for o in objects if o["detection_type"] == "weapon"]

    result = {
        "source_path": str(source),
        "source_type": "image" if is_image else "video",
        "crops_folder": str(crops_dir),
        "total_objects": len(objects),
        "vehicle_count": len(vehicles),
        # person_count = different people the tracker followed (can be too
        # high if someone was hidden and came back with a new ID);
        # max_people_at_once = most people visible together (the safer number)
        "person_count": len(people),
        "weapon_count": len(weapons),
        **detector.last_run_stats,
        "detections": objects,   # one per object
        # gunfire / explosions heard (videos only); AI leads to check by ear
        **sound,
    }
    print_file_summary(result, vehicles, people, weapons, is_image)
    return result


def print_file_summary(result, vehicles, people, weapons, is_image):
    print(f"Found {len(vehicles)} vehicle(s), {len(people)} person(s) "
          f"and {len(weapons)} weapon(s).")
    for v in vehicles:
        # percentages = how many of the car's frames agreed on the answer
        # "unsure: Opel?" = the best guess had too little agreement to report
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
            f"{part} {p[key] or 'unsure'}" for part, key in
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


# ---------------------------------------------------------------------------
# The submission
# ---------------------------------------------------------------------------

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
    detector = ArgusDetector()                 # load the models once for all files

    results = []
    for index, source in enumerate(files, start=1):
        print(f"\n=== File {index}/{len(files)}: {source.name} ===")
        file_crops = folder / file_folder_name(index, source)
        try:
            results.append(analyse_file(detector, source, file_crops))
        except Exception as error:             # one bad file doesn't stop the rest
            print(f"Could not process {source.name}: {error}")
            results.append({"source_path": str(source), "error": str(error)})

    ok = [r for r in results if "error" not in r]
    submission = {
        "submission": number,
        "processed_at": datetime.now().isoformat(),
        "model_version": detector.model_version,
        "file_count": len(files),
        # totals over all files - note the same person/vehicle filmed in two
        # clips is counted once per clip
        "totals": {
            "vehicles": sum(r["vehicle_count"] for r in ok),
            "people": sum(r["person_count"] for r in ok),
            "weapons": sum(r["weapon_count"] for r in ok),
            "audio_events": sum(len(r["audio_events"]) for r in ok),
        },
        "files": results,
    }
    for path in (folder / "results.json", Path("output_detections.json")):
        with open(path, "w", encoding="utf-8") as f:
            json.dump(submission, f, indent=2)

    t = submission["totals"]
    print(f"\n=== Submission {number} done: {len(ok)}/{len(files)} file(s) processed - "
          f"{t['vehicles']} vehicle(s), {t['people']} person(s), {t['weapons']} weapon(s), "
          f"{t['audio_events']} gunfire/explosion sound(s) ===")
    if t["weapons"] or t["audio_events"]:
        print("Reminder: CIT guards are armed too - a weapon or shot is a lead "
              "for the investigator, not proof of who the robber is.")
    print(f"Results: {folder / 'results.json'} (copy in output_detections.json); "
          f"pictures in {folder}")


if __name__ == "__main__":
    main()
