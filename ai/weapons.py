"""
weapons.py - finds WEAPONS in the video and links each one to the person
holding it.

Four kinds of weapon (what investigators need, not exact models):
    handgun    pistols, revolvers
    long_gun   rifles (incl. AK-style), shotguns
    knife      short blades
    machete    long blades, pangas

A camera can't tell automatic from semi-automatic (an AK-47 and a
semi-automatic rifle look the same) - that comes from the SOUND, see audio.py.

Which model:
  1. weapon_models/best.pt, if it exists: our own model, trained on labelled
     weapon pictures (see README, "Training the weapon model"). Most accurate.
  2. Otherwise YOLOE (Ultralytics, open-vocabulary): it finds objects from a
     plain-text description ("handgun", "rifle", ...) without any training.
     A useful stopgap, but less accurate - expect some misses and some false
     alarms (phones, drills, tools held like a gun).
  YOLOE's model files download by themselves the first time (about 30 MB
  plus its small text model); best.pt needs no download.

What it reports per weapon:
  * its kind (voted over frames, like a vehicle's make) and how sure
  * when it was visible, and its clearest picture (crops/weapon_<id>.png)
  * the person holding it: the tracked person whose box the weapon is in
    most often (held_by_person = that person's track_id)

IMPORTANT for investigators: CIT guards carry guns too. A weapon next to a
person says nothing about who is the robber - same rule as faces: "weapon
seen", never "suspect". Small or distant weapons are often missed, so "no
weapon found" does NOT mean there were none.
"""

from collections import Counter
from pathlib import Path

import cv2

MODELS = Path(__file__).parent / "weapon_models"
# Own tracker settings: lower thresholds than for people/vehicles
WEAPON_TRACKER = str(Path(__file__).parent / "weapon_tracker.yaml")
TRAINED_MODEL = MODELS / "best.pt"

# SWITCH: True = use our trained model (weapon_models/best.pt) when it exists;
# False = always use YOLOE. Set to False while the trained model is worse
# than YOLOE. Version 1 was (guns at 8-13% confidence); version 2 (11 Oct,
# mAP50 0.64 clear / 0.60 bad footage) beat YOLOE on our test clips.
USE_TRAINED_MODEL = True
YOLOE_MODEL = "yoloe-26s-seg.pt"

WEAPON_KINDS = ["handgun", "long_gun", "knife", "machete"]

# Text prompts for YOLOE -> our four kinds. Several wordings per kind find
# more (the model learnt from captions written by many different people).
YOLOE_PROMPTS = {
    "handgun": "handgun",
    "pistol": "handgun",
    "revolver": "handgun",
    "rifle": "long_gun",
    "assault rifle": "long_gun",
    "shotgun": "long_gun",
    "knife": "knife",
    "machete": "machete",
}

# Class names a trained model might use -> our four kinds. Anything not in
# here (e.g. "person" if the dataset had it) is ignored.
TRAINED_NAMES = {
    "handgun": "handgun", "pistol": "handgun", "revolver": "handgun", "gun": "handgun",
    "long_gun": "long_gun", "rifle": "long_gun", "shotgun": "long_gun",
    "automatic rifle": "long_gun", "assault_rifle": "long_gun",
    "knife": "knife", "blade": "knife",
    "machete": "machete", "panga": "machete",
}


def _overlap_share(inner, outer):
    """How much of box `inner` lies inside box `outer` (0-1)."""
    x1, y1 = max(inner[0], outer[0]), max(inner[1], outer[1])
    x2, y2 = min(inner[2], outer[2]), min(inner[3], outer[3])
    if x2 <= x1 or y2 <= y1:
        return 0.0
    area = (inner[2] - inner[0]) * (inner[3] - inner[1])
    return (x2 - x1) * (y2 - y1) / area if area > 0 else 0.0


def holder(weapon_box, people, min_share=0.5):
    """track_id of the person most likely holding the weapon, or None.

    people: [(person track_id, [x1, y1, x2, y2]), ...]. A person's box is
    widened by 25% each side first, because an arm holding a gun often
    sticks out of the body's box.
    """
    best, best_share, best_dist = None, 0.0, None
    wx, wy = (weapon_box[0] + weapon_box[2]) / 2, (weapon_box[1] + weapon_box[3]) / 2
    for person_id, (x1, y1, x2, y2) in people:
        pad = (x2 - x1) * 0.25
        share = _overlap_share(weapon_box, (x1 - pad, y1, x2 + pad, y2))
        if share < min_share:
            continue
        dist = abs(wx - (x1 + x2) / 2) + abs(wy - (y1 + y2) / 2)
        if share > best_share or (share == best_share and dist < best_dist):
            best, best_share, best_dist = person_id, share, dist
    return best


class WeaponFinder:
    """Finds and tracks weapons frame by frame (own tracker, own IDs)."""

    def __init__(self, tracker=WEAPON_TRACKER):
        from ultralytics import YOLO, YOLOE
        self.tracker = tracker
        if USE_TRAINED_MODEL and TRAINED_MODEL.exists():
            self.model = YOLO(str(TRAINED_MODEL))
            names = self.model.names
            self.kind_of = {i: TRAINED_NAMES.get(str(n).lower().strip())
                            for i, n in (names.items() if isinstance(names, dict)
                                         else enumerate(names))}
            self.version = "weapons-trained"
            self.default_conf = 0.4
        else:
            self.model = YOLOE(YOLOE_MODEL)
            prompts = list(YOLOE_PROMPTS)
            self._set_prompts(prompts)
            self.kind_of = {i: YOLOE_PROMPTS[p] for i, p in enumerate(prompts)}
            self.version = Path(YOLOE_MODEL).stem + "-text"
            self.default_conf = 0.3                   # open-vocabulary scores run lower
        self.reset()

    def _set_prompts(self, prompts):
        """Tells YOLOE what to look for. Turning text into the model's numbers
        needs a text model (and the 'clip' package, which Ultralytics installs
        by itself the first time - this needs Git installed). The result is
        saved to weapon_models/yoloe_prompts.npz, so later runs - and anyone
        who gets that file through Git - skip this step entirely."""
        cache = MODELS / "yoloe_prompts.npz"
        if cache.exists():
            try:
                self.model.load_prompt_embeddings(cache)
                names = self.model.names
                names = list(names.values()) if isinstance(names, dict) else list(names)
                if names == prompts:
                    return
            except Exception:
                pass                                  # wrong/old file: rebuild it
        try:
            self.model.set_classes(prompts)
        except Exception as error:
            raise RuntimeError(
                "could not prepare the weapon text prompts - install Git "
                "(https://git-scm.com) and run again, or get "
                "weapon_models/yoloe_prompts.npz from a teammate") from error
        MODELS.mkdir(exist_ok=True)
        try:
            self.model.save_prompt_embeddings(cache)
        except Exception:
            pass                                      # works, just not cached

    def reset(self):
        """Forget everything (call before each new video / photo)."""
        self.records = {}                             # weapon id -> record
        self._next_photo_id = 1
        self.model.predictor = None                   # fresh tracker

    # --- one picture -------------------------------------------------------

    def _boxes(self, results, frame, max_area=0.5):
        """[(weapon id or None, kind, confidence, [x1, y1, x2, y2])] from a result.
        Boxes covering more than `max_area` of the picture are dropped: in
        street footage a "gun" that big is almost always a mistake."""
        boxes = results.boxes
        if boxes is None or len(boxes) == 0:
            return []
        h, w = frame.shape[:2]
        ids = boxes.id if boxes.id is not None else [None] * len(boxes)
        found = []
        for box, weapon_id in zip(boxes, ids):
            kind = self.kind_of.get(int(box.cls[0]))
            if kind is None:
                continue
            xyxy = [round(float(v), 1) for v in box.xyxy[0]]
            bw, bh = xyxy[2] - xyxy[0], xyxy[3] - xyxy[1]
            if bw * bh > max_area * w * h:
                continue
            found.append((None if weapon_id is None else int(weapon_id),
                          kind, float(box.conf[0]), xyxy))
        return found

    def add_frame(self, frame, frame_number, frame_time, people, min_conf=0.15):
        """Looks for weapons in one video frame. people = [(track_id, box)].

        Low-scoring boxes (down to `min_conf`) go to the tracker on purpose:
        it only STARTS a weapon track from a sure detection (weapon_tracker.yaml,
        new_track_thresh), then uses the weaker ones to follow that weapon
        through blurry frames."""
        conf = min_conf
        results = self.model.track(frame, persist=True, tracker=self.tracker,
                                   conf=conf, verbose=False)[0]
        for weapon_id, kind, confidence, xyxy in self._boxes(results, frame):
            if weapon_id is not None:
                self._record(weapon_id, kind, confidence, xyxy, frame,
                             frame_number, frame_time, people)

    def add_image(self, frame, people, min_conf=None):
        """Looks for weapons in one photo (no tracking: each gets its own id)."""
        conf = self.default_conf if min_conf is None else min_conf
        results = self.model.predict(frame, conf=conf, verbose=False)[0]
        # a photo may be a close-up of a weapon left at the scene: allow big boxes
        for _, kind, confidence, xyxy in self._boxes(results, frame, max_area=0.95):
            self._record(self._next_photo_id, kind, confidence, xyxy, frame, 1, 0.0, people)
            self.records[self._next_photo_id]["photo"] = True
            self._next_photo_id += 1

    def _record(self, weapon_id, kind, confidence, xyxy, frame, frame_number,
                frame_time, people):
        r = self.records.setdefault(weapon_id, {
            "kind_votes": Counter(), "holder_votes": Counter(),
            "frames_seen": 0, "first_seen_seconds": frame_time,
            "best_score": -1.0, "best_crop": None,
        })
        r["frames_seen"] += 1
        r["last_seen_seconds"] = frame_time
        r["kind_votes"][kind] += confidence
        person = holder(xyxy, people)
        if person is not None:
            r["holder_votes"][person] += 1
        width, height = xyxy[2] - xyxy[0], xyxy[3] - xyxy[1]
        score = width * height * confidence
        if score > r["best_score"]:
            fh, fw = frame.shape[:2]
            r.update(best_score=score, confidence=round(confidence, 3),
                     bounding_box=xyxy, frame_number=frame_number,
                     frame_time_seconds=frame_time,
                     area_share=width * height / (fw * fh))
            mx, my = width * 0.3, height * 0.3          # a bit of the hand/arm too
            x1, y1 = max(0, int(xyxy[0] - mx)), max(0, int(xyxy[1] - my))
            x2, y2 = min(fw, int(xyxy[2] + mx)), min(fh, int(xyxy[3] + my))
            if x2 > x1 and y2 > y1:
                r["best_crop"] = frame[y1:y2, x1:x2].copy()

    # --- results -----------------------------------------------------------

    def results(self, min_frames=3, min_answer_share=0.4, crops_dir=None,
                max_lone_area=0.15, min_lone_frames=5):
        """One dictionary per weapon seen in at least `min_frames` frames.

        In videos, a "weapon" that nobody is holding AND that fills more than
        `max_lone_area` of the picture is dropped: that is scenery (the
        trained model once called a long straight road a rifle). A real
        weapon that big is a close-up, and then someone is holding it.
        A video "weapon" nobody holds must also be seen in at least
        `min_lone_frames` frames (a 3-frame "knife" in a street corner was
        a false alarm)."""
        objects = []
        for weapon_id, r in sorted(self.records.items()):
            if r["frames_seen"] < min_frames:
                continue                  # one-frame "weapons" are usually mistakes
            total = sum(r["kind_votes"].values())
            ranked = r["kind_votes"].most_common(3)
            kind, weight = ranked[0]
            share = round(weight / total, 2)
            holder_id, holder_frames = (r["holder_votes"].most_common(1)[0]
                                        if r["holder_votes"] else (None, 0))
            if holder_id is None and not r.get("photo") and (
                    r["area_share"] > max_lone_area or r["frames_seen"] < min_lone_frames):
                continue
            obj = {
                "track_id": weapon_id,
                "detection_type": "weapon",
                # None = the frames disagreed too much about the kind
                "class_name": kind if share >= min_answer_share else None,
                "weapon_confidence": share,
                "weapon_top3": {k: round(v / total, 2) for k, v in ranked},
                "confidence": r["confidence"],          # detector's, clearest view
                "bounding_box": r["bounding_box"],
                "frame_number": r["frame_number"],
                "frame_time_seconds": r["frame_time_seconds"],
                "first_seen_seconds": r["first_seen_seconds"],
                "last_seen_seconds": r["last_seen_seconds"],
                "frames_seen": r["frames_seen"],
                # the person (track_id) it was with most often; None = nobody
                "held_by_person": holder_id,
                "held_by_share": round(holder_frames / r["frames_seen"], 2),
                "model_version": self.version,
            }
            if crops_dir and r["best_crop"] is not None and r["best_crop"].size:
                folder = Path(crops_dir)
                folder.mkdir(parents=True, exist_ok=True)
                crop = r["best_crop"]
                if crop.shape[0] < 200:          # enlarge small weapons to look at
                    scale = 200 / crop.shape[0]
                    crop = cv2.resize(crop, None, fx=scale, fy=scale,
                                      interpolation=cv2.INTER_CUBIC)
                path = folder / f"weapon_{weapon_id}.png"
                cv2.imwrite(str(path), crop)
                obj["crop_path"] = str(path)
            objects.append(obj)
        return objects
