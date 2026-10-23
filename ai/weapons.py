"""
Finds weapons and links each one to whoever's holding it.

We only care about four kinds, since that's what investigators need:
handgun, long_gun (rifles, AKs, shotguns), knife and machete (incl. pangas).
Automatic vs semi-auto can't be seen on camera, an AK and a semi-auto rifle
look identical. That comes from the audio instead (audio.py).

Model: if weapon_models/best.pt exists we use that, it's our own trained
model and the most accurate (see the README for how it was trained).
Otherwise we fall back to YOLOE, which takes plain-text prompts like
"handgun" and needs no training. It's a decent stopgap but misses more and
sometimes mistakes phones or drills for guns.

For each weapon we report the kind (voted over frames), when it was seen,
its best crop, and the person it was inside the box of most often.

Please keep in mind: CIT guards are armed too. A gun next to someone tells
you nothing about who the robber is, so it's "weapon seen", never
"suspect". And small or far-off weapons get missed a lot, so finding none
doesn't mean there weren't any.
"""

from collections import Counter
from pathlib import Path

import cv2

MODELS = Path(__file__).parent / "weapon_models"
# separate tracker config with lower thresholds, see the yaml
WEAPON_TRACKER = str(Path(__file__).parent / "weapon_tracker.yaml")
TRAINED_MODEL = MODELS / "best.pt"

# Flip to False to force YOLOE. Our first trained model was worse than YOLOE
# (guns at 8-13% confidence), v2 from 11 Oct (mAP50 0.64 clean / 0.60 rough
# footage) beats it on our test clips.
USE_TRAINED_MODEL = True
YOLOE_MODEL = "yoloe-26s-seg.pt"

WEAPON_KINDS = ["handgun", "long_gun", "knife", "machete"]

# YOLOE prompt -> our kind. More phrasings = more hits, since the model
# learnt from captions written by lots of different people.
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

# Whatever class names a trained model might use, mapped to our four. Anything
# not listed (like "person") gets ignored.
TRAINED_NAMES = {
    "handgun": "handgun", "pistol": "handgun", "revolver": "handgun", "gun": "handgun",
    "long_gun": "long_gun", "rifle": "long_gun", "shotgun": "long_gun",
    "automatic rifle": "long_gun", "assault_rifle": "long_gun",
    "knife": "knife", "blade": "knife",
    "machete": "machete", "panga": "machete",
}


def _overlap_share(inner, outer):
    """Fraction of `inner` that sits inside `outer`."""
    x1, y1 = max(inner[0], outer[0]), max(inner[1], outer[1])
    x2, y2 = min(inner[2], outer[2]), min(inner[3], outer[3])
    if x2 <= x1 or y2 <= y1:
        return 0.0
    area = (inner[2] - inner[0]) * (inner[3] - inner[1])
    return (x2 - x1) * (y2 - y1) / area if area > 0 else 0.0


def holder(weapon_box, people, min_share=0.5):
    """track_id of whoever is most likely holding the weapon, or None.

    We widen each person's box by 25% on both sides first, since an arm
    holding a gun often sticks out past the body.
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
    """Detects and tracks weapons, with its own tracker and IDs."""

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
            self.default_conf = 0.3                   # open-vocab scores run lower
        self.reset()

    def _set_prompts(self, prompts):
        """Tell YOLOE what to look for.

        Turning the prompts into embeddings needs a text model plus the 'clip'
        package, which Ultralytics installs on the fly (needs Git). That's a
        pain, so we cache the result in weapon_models/yoloe_prompts.npz and
        commit it, and nobody else has to do this step.
        """
        cache = MODELS / "yoloe_prompts.npz"
        if cache.exists():
            try:
                self.model.load_prompt_embeddings(cache)
                names = self.model.names
                names = list(names.values()) if isinstance(names, dict) else list(names)
                if names == prompts:
                    return
            except Exception:
                pass                                  # stale cache, rebuild below
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
                pass                                      # fine, just won't be cached

    def reset(self):
        """Clear everything. Call this before each new video or photo."""
        self.records = {}
        self._next_photo_id = 1
        self.model.predictor = None                   # resets the tracker

    # --- per frame

    def _boxes(self, results, frame, max_area=0.5):
        """Pull (id, kind, conf, box) out of a result. Anything covering more
        than `max_area` of the frame gets dropped, in street footage a "gun"
        that big is basically always wrong."""
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
        """Check one video frame for weapons.

        We pass low-confidence boxes to the tracker on purpose. It only starts
        a track from a confident detection (new_track_thresh), but then uses
        the weaker ones to keep following the weapon through blurry frames.
        """
        conf = min_conf
        results = self.model.track(frame, persist=True, tracker=self.tracker,
                                   conf=conf, verbose=False)[0]
        for weapon_id, kind, confidence, xyxy in self._boxes(results, frame):
            if weapon_id is not None:
                self._record(weapon_id, kind, confidence, xyxy, frame,
                             frame_number, frame_time, people)

    def add_image(self, frame, people, min_conf=None):
        """Check a single photo. No tracking, each weapon gets its own id."""
        conf = self.default_conf if min_conf is None else min_conf
        results = self.model.predict(frame, conf=conf, verbose=False)[0]
        # photos can be close-ups of a weapon left at the scene, so allow big boxes
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
            mx, my = width * 0.3, height * 0.3          # include a bit of the hand
            x1, y1 = max(0, int(xyxy[0] - mx)), max(0, int(xyxy[1] - my))
            x2, y2 = min(fw, int(xyxy[2] + mx)), min(fh, int(xyxy[3] + my))
            if x2 > x1 and y2 > y1:
                r["best_crop"] = frame[y1:y2, x1:x2].copy()

    # --- results

    def results(self, min_frames=3, min_answer_share=0.4, crops_dir=None,
                max_lone_area=0.15, min_lone_frames=5):
        """One dict per weapon seen in at least `min_frames` frames.

        For videos we're extra suspicious of weapons nobody is holding. If one
        takes up more than `max_lone_area` of the frame it's almost certainly
        scenery (the trained model once decided a long straight road was a
        rifle), since a real weapon that close would be in someone's hand. And
        it has to show up in at least `min_lone_frames` frames, after a
        3-frame "knife" on a street corner turned out to be nothing.
        """
        objects = []
        for weapon_id, r in sorted(self.records.items()):
            if r["frames_seen"] < min_frames:
                continue
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
                # None if the frames couldn't agree on what kind it is
                "class_name": kind if share >= min_answer_share else None,
                "weapon_confidence": share,
                "weapon_top3": {k: round(v / total, 2) for k, v in ranked},
                "confidence": r["confidence"],          # detector score at the best view
                "bounding_box": r["bounding_box"],
                "frame_number": r["frame_number"],
                "frame_time_seconds": r["frame_time_seconds"],
                "first_seen_seconds": r["first_seen_seconds"],
                "last_seen_seconds": r["last_seen_seconds"],
                "frames_seen": r["frames_seen"],
                # track_id of the person it was with most often
                "held_by_person": holder_id,
                "held_by_share": round(holder_frames / r["frames_seen"], 2),
                "model_version": self.version,
            }
            if crops_dir and r["best_crop"] is not None and r["best_crop"].size:
                folder = Path(crops_dir)
                folder.mkdir(parents=True, exist_ok=True)
                crop = r["best_crop"]
                if crop.shape[0] < 200:          # blow small ones up so they're easier to see
                    scale = 200 / crop.shape[0]
                    crop = cv2.resize(crop, None, fx=scale, fy=scale,
                                      interpolation=cv2.INTER_CUBIC)
                path = folder / f"weapon_{weapon_id}.png"
                cv2.imwrite(str(path), crop)
                obj["crop_path"] = str(path)
            objects.append(obj)
        return objects
