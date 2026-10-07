"""
main.py - run the detector on one video OR one photo and save the results.

Usage:
    python main.py path\\to\\video.mp4
    python main.py path\\to\\photo.jpg

Photos: JPEG, PNG, WebP, BMP, TIFF, GIF and iPhone HEIC/HEIF.
Videos: MP4, MOV, AVI, MKV, M4V, 3GP, WebM (and anything else OpenCV opens).

Saves output_detections.json (one entry per vehicle/person), PNG pictures in
the crops folder (each vehicle's clearest view and plate, people whose face is
clear enough), and prints a summary, e.g.:

    Vehicle #3  car  Toyota (90%)  white (80%)  plate CA123456 (85%, 9 reads)  seen in 15 frames
    Most people visible at once: 3 (at 4.2 s)
    Person  #7  top black / bottom blue   face visible (52 px) - picture saved
"""

import json
import sys
from datetime import datetime
from pathlib import Path

from detector import IMAGE_TYPES, ArgusDetector


def main():
    if len(sys.argv) < 2:
        print("Usage: python main.py path\\to\\video.mp4  (or a photo, e.g. photo.jpg)")
        return

    source = Path(sys.argv[1])
    if not source.is_file():
        print(f"File not found: {source}")
        return
    is_image = source.suffix.lower() in IMAGE_TYPES

    detector = ArgusDetector()
    if is_image:
        objects = detector.process_image(source, crops_dir="crops")
    else:
        objects = detector.process_video(source, crops_dir="crops")

    vehicles = [o for o in objects if o["detection_type"] == "vehicle"]
    people = [o for o in objects if o["detection_type"] == "person"]

    output = {
        "source_path": str(source),
        "source_type": "image" if is_image else "video",
        "processed_at": datetime.now().isoformat(),
        "model_version": detector.model_version,
        "total_objects": len(objects),
        "vehicle_count": len(vehicles),
        # person_count = different people the tracker followed (can be too
        # high if someone was hidden and came back with a new ID);
        # max_people_at_once = most people visible together (the safer number)
        "person_count": len(people),
        **detector.last_run_stats,
        "detections": objects,   # one per object
    }

    with open("output_detections.json", "w", encoding="utf-8") as f:
        json.dump(output, f, indent=2)

    print(f"Found {len(vehicles)} vehicle(s) and {len(people)} person(s).")
    for v in vehicles:
        # percentages = how many of the car's frames agreed on the answer
        # "unsure: Opel?" = the best guess had too little agreement to report
        def describe(answer, share, top3, what):
            if answer:
                return f"{answer} ({round(share * 100)}%)"
            if top3:
                return f"unsure: {next(iter(top3))}?"
            return f"{what} unknown"
        make = describe(v["make"], v["make_confidence"], v["make_top3"], "make")
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

    stats = detector.last_run_stats
    if stats.get("max_people_at_once"):
        if is_image:
            print(f"People in the photo: {stats['max_people_at_once']}")
        else:
            print(f"Most people visible at once: {stats['max_people_at_once']} "
                  f"(at {stats['max_people_time_seconds']} s)")
    for p in people:
        clothing = " / ".join(
            f"{part} {p[key] or 'unsure'}" for part, key in
            (("top", "upper_clothing"), ("bottom", "lower_clothing")))
        face = (f"face visible ({p['face_size_px']} px) - picture saved"
                if p["face_visible"] else
                f"face not clear enough (biggest {p['face_size_px']} px)" if p["face_size_px"]
                else "no face seen")
        print(f"  Person  #{p['track_id']:<3} {clothing:<32} {face}")
    print("Saved to output_detections.json (PNG pictures in the crops folder)")


if __name__ == "__main__":
    main()
