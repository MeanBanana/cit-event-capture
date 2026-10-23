"""
The main detector. Takes a video (or a photo, see process_image), finds the
vehicles, people and weapons in it, follows them across frames, and figures
out make, colour and plate for each vehicle.

Rough flow:
  - YOLO26s boxes everything per frame, and the tracker (argus_tracker.yaml)
    keeps the same ID on the same object even through shake or brief
    occlusion.
  - Every few frames we crop each decent vehicle and ask the Spectrico models
    (vehicle_classifier.py) for make/colour probabilities. We add those up
    across frames, giving close, sharp, confident views more say and ignoring
    tiny, blurry or cut-off ones.
  - Plates get read on the same good views (plate_reader.py).
  - People get clothing colours and their best face shot (people.py). We
    only find faces, we never try to identify anyone (POPIA).
  - Each track turns into one result. If the views don't agree enough on
    something, we report None rather than guess.
  - Everyone/everything also gets an appearance fingerprint (appearance.py)
    so the case matcher can link them across submissions.

No MNN / Spectrico models? It still works, colour just falls back to k-means
and make stays empty.

Output lines up with the `detection` + `vehicledetail` tables, one row per
real object (database/README.md has the details).
"""

from collections import Counter
from pathlib import Path

import cv2
import numpy as np
from ultralytics import YOLO

from colours import dominant_colour
from people import FaceFinder, PersonRecord
from clothing import PoseFinder

try:
    from vehicle_classifier import VehicleClassifier, sharpness
except ImportError as error:          # usually means MNN isn't installed
    VehicleClassifier = None
    _CLASSIFIER_ERROR = error

    # Copy of vehicle_classifier.sharpness so we don't need MNN just for this
    def sharpness(bgr_crop):
        grey = cv2.resize(cv2.cvtColor(bgr_crop, cv2.COLOR_BGR2GRAY), (224, 224))
        return float(cv2.Laplacian(grey, cv2.CV_64F).var())

try:
    from weapons import WeaponFinder
except ImportError as error:
    WeaponFinder = None
    _WEAPON_IMPORT_ERROR = error

try:
    from appearance import AppearanceModel
except ImportError as error:
    AppearanceModel = None
    _APPEARANCE_IMPORT_ERROR = error

try:
    from plate_reader import PlateReader, PlateVotes
except ImportError as error:
    PlateReader, PlateVotes = None, None
    _PLATE_IMPORT_ERROR = error

HERE = Path(__file__).parent

# We moved up from yolov8n to yolo26s because the small model kept missing
# far-off and half-hidden cars. It's slower, but worth it. Downloads itself
# (~20 MB) on first run. yolo26n is faster, yolo26m is more accurate.
DEFAULT_MODEL = "yolo26s.pt"

TRACKER_CONFIG = str(HERE / "argus_tracker.yaml")

# COCO class ids
VEHICLE_CLASSES = {2: "car", 3: "motorcycle", 5: "bus", 7: "truck"}
PERSON_CLASS = 0



# --- k-means colour fallback (only used when the Spectrico model isn't loaded)

def vehicle_colour(frame, box, min_size=40):
    """Main colour of the vehicle in `box`, or None if it's too small to tell."""
    height, width = frame.shape[:2]
    x1, y1, x2, y2 = (int(round(v)) for v in box)
    x1, y1 = max(0, x1), max(0, y1)
    x2, y2 = min(width, x2), min(height, y2)
    if x2 - x1 < min_size or y2 - y1 < min_size:
        return None  # any answer here would just be a guess

    car = frame[y1:y2, x1:x2]
    h, w = car.shape[:2]

    # Only look at the middle of the box. The edges tend to be road/sky, the
    # top is windows and the bottom is tyres and shadow.
    body = car[int(h * 0.30):int(h * 0.80), int(w * 0.15):int(w * 0.85)]
    return dominant_colour(body)


# --- detection + tracking helpers

def crop_box(frame, box, margin=0.05):
    """Crop the box out of the frame with a little padding. None if empty."""
    height, width = frame.shape[:2]
    x1, y1, x2, y2 = box
    mx, my = (x2 - x1) * margin, (y2 - y1) * margin
    x1, y1 = max(0, int(x1 - mx)), max(0, int(y1 - my))
    x2, y2 = min(width, int(x2 + mx)), min(height, int(y2 + my))
    if x2 <= x1 or y2 <= y1:
        return None
    return frame[y1:y2, x1:x2]


def touches_edge(box, frame, gap=3):
    """Is the box touching the frame edge? Half a car tends to get the wrong make."""
    height, width = frame.shape[:2]
    x1, y1, x2, y2 = box
    return x1 <= gap or y1 <= gap or x2 >= width - gap or y2 >= height - gap


def view_quality(box, sharp, confidence):
    """Weight (0-1) for one frame's vote.

    Full weight at 224px (the classifier's input size) and sharpness 150,
    scaled down below that, then multiplied by YOLO's confidence.
    """
    width, height = box[2] - box[0], box[3] - box[1]
    size_factor = min(1.0, min(width, height) / 224)
    sharp_factor = min(1.0, sharp / 150)
    return size_factor * sharp_factor * confidence


def _soft_winner(scores, labels):
    """Pick the winner from summed probabilities.

    Returns (label, share, top3) or (None, 0.0, {}) if nothing got scored.
    """
    total = float(scores.sum()) if scores is not None else 0.0
    if total <= 0:
        return None, 0.0, {}
    order = np.argsort(scores)[::-1][:3]
    top3 = {labels[i]: round(float(scores[i]) / total, 2) for i in order
            if scores[i] / total >= 0.01}
    best = int(order[0])
    return labels[best], round(float(scores[best]) / total, 2), top3


def _count_winner(votes):
    """Most common answer and its share of the votes."""
    if not votes:
        return None, 0.0
    answer, count = votes.most_common(1)[0]
    return answer, round(count / sum(votes.values()), 2)


# HEIC/HEIF (iPhone) only works if pillow-heif is installed
IMAGE_TYPES = {".jpg", ".jpeg", ".png", ".bmp", ".webp", ".tif", ".tiff",
               ".gif", ".heic", ".heif"}


def load_image(path):
    """Load a photo as BGR, rotated the right way up.

    Phones often save photos sideways and rely on the EXIF orientation tag.
    If we ignore it everyone ends up lying on their side and YOLO misses them,
    hence exif_transpose. Transparency gets flattened onto white, and for GIFs
    we just take the first frame. If Pillow chokes we try OpenCV instead.
    """
    path = Path(path)
    if not path.is_file():
        raise FileNotFoundError(f"Could not find image: {path}")
    try:
        from PIL import Image, ImageOps
        try:
            import pillow_heif
            pillow_heif.register_heif_opener()
        except ImportError:
            pass
        with Image.open(path) as img:
            img = ImageOps.exif_transpose(img)
            if img.mode in ("RGBA", "LA", "P"):
                img = img.convert("RGBA")
                background = Image.new("RGBA", img.size, (255, 255, 255, 255))
                img = Image.alpha_composite(background, img)
            rgb = np.array(img.convert("RGB"))
        return cv2.cvtColor(rgb, cv2.COLOR_RGB2BGR)
    except Exception as pil_error:
        # cv2.imread can't handle non-ASCII paths on Windows, this can
        data = np.fromfile(str(path), dtype=np.uint8)
        frame = cv2.imdecode(data, cv2.IMREAD_COLOR) if data.size else None
        if frame is None:
            hint = (" - for iPhone HEIC photos run: pip install pillow-heif"
                    if path.suffix.lower() in (".heic", ".heif") else "")
            raise ValueError(f"Could not read image: {path}{hint}") from pil_error
        return frame


def _keep_view(track, quality, frame_time, crop, keep=12):
    """Hang on to the track's best few views (used for the fingerprint and
    the extra crops). Anything worse than the current top `keep` is dropped."""
    views = track["views"]
    if len(views) >= keep and quality <= views[-1][0]:
        return
    views.append((quality, frame_time, crop.copy()))
    views.sort(key=lambda v: -v[0])
    del views[keep:]


def _spread_views(views, count=6, min_gap=0.4):
    """Best views, spaced at least `min_gap` seconds apart. Six near-identical
    frames don't tell us much more than one does."""
    chosen = []
    for view in views:                    # views is sorted best-first already
        if all(abs(view[1] - c[1]) >= min_gap for c in chosen):
            chosen.append(view)
        if len(chosen) == count:
            break
    return chosen


def drop_duplicate_people(detections, inside=0.9, same_height=0.1):
    """Get rid of double boxes on one person.

    YOLO sometimes gives one person a tight box plus a wider one that takes
    in their arms (someone aiming a rifle, say). Both boxes share the same
    top and bottom. Someone standing behind them would look smaller, so their
    top/bottom won't line up and they survive this.

    A box goes if it's mostly (`inside`) within a more confident box and the
    tops and bottoms are within `same_height` of each other.
    """
    people = [d for d in detections if d[1] == PERSON_CLASS]
    others = [d for d in detections if d[1] != PERSON_CLASS]
    kept = []
    for det in sorted(people, key=lambda d: -d[2]):
        x1, y1, x2, y2 = det[3]
        area = max(1e-6, (x2 - x1) * (y2 - y1))
        duplicate = False
        for k in kept:
            kx1, ky1, kx2, ky2 = k[3]
            ix = max(0.0, min(x2, kx2) - max(x1, kx1))
            iy = max(0.0, min(y2, ky2) - max(y1, ky1))
            small = min(area, (kx2 - kx1) * (ky2 - ky1))
            h = max(y2 - y1, ky2 - ky1)
            if (ix * iy >= inside * small and abs(y1 - ky1) <= same_height * h
                    and abs(y2 - ky2) <= same_height * h):
                duplicate = True
                break
        if not duplicate:
            kept.append(det)
    return others + kept


def same_vehicle(a, b, min_iou=0.6, inside=0.85, min_area_ratio=0.6):
    """Are these two boxes really the same vehicle?

    Yes if they overlap heavily, or one sits almost entirely inside the other
    and they're roughly the same size. The size check is what stops a small
    car parked in front of a truck from being merged into it.
    """
    ix = max(0.0, min(a[2], b[2]) - max(a[0], b[0]))
    iy = max(0.0, min(a[3], b[3]) - max(a[1], b[1]))
    inter = ix * iy
    area_a = max(1e-6, (a[2] - a[0]) * (a[3] - a[1]))
    area_b = max(1e-6, (b[2] - b[0]) * (b[3] - b[1]))
    if inter / (area_a + area_b - inter) >= min_iou:
        return True
    small, big = min(area_a, area_b), max(area_a, area_b)
    return inter >= inside * small and small / big >= min_area_ratio


def drop_duplicate_vehicles(detections, **rules):
    """Get rid of double boxes on one vehicle.

    YOLO26 doesn't do NMS across classes, so a bakkie or minibus regularly
    comes back as both a "car" and a "truck"/"bus". Without this we'd end up
    reporting a silver car AND a silver truck for the same bakkie. We keep
    whichever box YOLO was more sure of.
    """
    vehicles = [d for d in detections if d[1] in VEHICLE_CLASSES]
    others = [d for d in detections if d[1] not in VEHICLE_CLASSES]
    kept = []
    for det in sorted(vehicles, key=lambda d: -d[2]):
        if not any(same_vehicle(det[3], k[3], **rules) for k in kept):
            kept.append(det)
    return others + kept


def _drop_duplicate_vehicle_boxes(predictor):
    """Ultralytics hook that dedupes vehicle boxes before the tracker sees
    them, otherwise one bakkie turns into two tracks.

    Order matters here: this has to be registered before the first track()
    call so it runs ahead of the tracker's own callback.
    """
    for i, result in enumerate(predictor.results):
        boxes = result.boxes
        if boxes is None or len(boxes) < 2:
            continue
        dets = [(j, int(c), float(s), [float(v) for v in xy])
                for j, (c, s, xy) in enumerate(zip(boxes.cls, boxes.conf, boxes.xyxy))]
        keep = sorted(d[0] for d in drop_duplicate_vehicles(dets))
        if len(keep) < len(dets):
            predictor.results[i] = result[keep]


def _boxed(frame, boxes):
    """Copy of the frame with orange boxes drawn on it."""
    picture = frame.copy()
    for x1, y1, x2, y2 in boxes:
        cv2.rectangle(picture, (int(x1), int(y1)), (int(x2), int(y2)),
                      (0, 165, 255), 2)
    return picture


class ArgusDetector:
    def __init__(self, model_path=DEFAULT_MODEL, tracker=TRACKER_CONFIG):
        self.model = YOLO(model_path)
        # Must be added before the first track() call, see the function itself
        self.model.add_callback("on_predict_postprocess_end", _drop_duplicate_vehicle_boxes)
        self.model_name = Path(model_path).stem
        self.tracker = tracker

        # All the models below are optional. If one fails to load we print a
        # warning and carry on with less information rather than crash.
        self.classifier = None
        if VehicleClassifier is None:
            print(f"Make/colour models not available ({_CLASSIFIER_ERROR}). "
                  "Run: pip install MNN. Using basic colour only.")
        else:
            try:
                self.classifier = VehicleClassifier()
            except Exception as error:
                print(f"Could not load make/colour models ({error}). "
                      "Using basic colour only.")

        self.faces = None
        try:
            self.faces = FaceFinder()
        except Exception as error:
            print(f"Face finding not available ({error}). "
                  "People will have no pictures.")

        # Pose tells us where the shirt ends and the trousers start (and if
        # it's just bare skin). Without it we guess using fixed slices of the
        # box, which goes badly wrong on close-ups.
        self.pose = None
        try:
            self.pose = PoseFinder(str(Path(__file__).parent / "yolo26s-pose.pt"))
        except Exception as error:
            print(f"Body pose model not available ({error}). "
                  "Clothing colours will be less reliable.")

        self.weapons = None
        if WeaponFinder is None:
            print(f"Weapon detection not available ({_WEAPON_IMPORT_ERROR}).")
        else:
            try:
                self.weapons = WeaponFinder()
            except Exception as error:
                print(f"Weapon detection not available ({error}).")

        self.appearance = None
        if AppearanceModel is None:
            print(f"Appearance matching not available ({_APPEARANCE_IMPORT_ERROR}).")
        else:
            try:
                self.appearance = AppearanceModel()
            except Exception as error:
                print(f"Appearance matching not available ({error}).")

        self.last_run_stats = {}

        self.plates = None
        if PlateReader is None:
            print(f"Plate reading not available ({_PLATE_IMPORT_ERROR}).")
        else:
            try:
                self.plates = PlateReader()
            except Exception as error:   # usually fast-alpr missing or no internet
                print(f"Plate reading not available ({error}). "
                      "Run: pip install -r requirements.txt")

    @property
    def model_version(self):
        """Stored with every detection so we know which models made it."""
        tracker = Path(self.tracker).stem
        parts = [self.model_name, tracker,
                 "spectrico-mobilenetv3" if self.classifier is not None else "kmeans-colour"]
        if self.plates is not None:
            parts.append(self.plates.version)
        if self.weapons is not None:
            parts.append(self.weapons.version)
        if self.appearance is not None:
            parts.append(self.appearance.version)
        return "+".join(parts)

    def process_video(self, video_path, sample_every=1, min_conf=0.4,
                      min_frames=3, min_vehicle_size=60, min_sharpness=15,
                      classify_every=3, min_answer_share=0.4,
                      min_colour_size=30, min_make_size=120, min_make_share=0.6,
                      min_person_height=80, min_face_px=36, weapon_every=2,
                      crops_dir=None):
        """Run the whole pipeline over a video. Returns one dict per object.

        The knobs, roughly:
          sample_every       only look at every Nth frame (2 is ~2x faster
                             but tracking gets a bit worse)
          min_conf           ignore YOLO boxes below this confidence
          min_frames         tracks shorter than this are treated as noise
          min_vehicle_size   min box size (px) before we try reading a plate
          min_colour_size    min box size for colour
          min_make_size      min box size for make. Badges need detail.
          min_make_share     make needs this much agreement or it's None.
                             Stricter than colour on purpose: a wrong brand
                             sends investigators after the wrong car.
          min_sharpness      skip blurrier crops for make/colour
          classify_every     classify each vehicle every Nth time we see it.
                             Neighbouring frames are near-identical anyway.
          min_answer_share   same idea as min_make_share, for everything else
          min_person_height  people shorter than this are skipped for
                             clothing/face
          min_face_px        smallest face worth saving (~5m away at 1080p)
          weapon_every       run the weapon model every Nth sampled frame.
                             It's a whole second model so this saves a lot.
          crops_dir          if set, dump PNG crops of everything in here
        """
        # Reset the tracker, otherwise IDs carry over from the previous video
        # when a submission has several files.
        self.model.predictor = None
        cap = cv2.VideoCapture(str(video_path))
        if not cap.isOpened():
            raise FileNotFoundError(f"Could not open video: {video_path}")

        fps = cap.get(cv2.CAP_PROP_FPS) or 25
        tracks = {}        # track_id -> everything we've learned about it
        frame_number = 0
        most_people, most_people_time, peak_frame = 0, None, None
        if self.weapons is not None:
            self.weapons.reset()
        sampled = 0

        while True:
            ok, frame = cap.read()
            if not ok:
                break
            frame_number += 1
            if frame_number % sample_every != 0:
                continue

            frame_time = round(frame_number / fps, 2)
            sampled += 1

            # persist=True keeps the tracker state between calls
            results = self.model.track(
                frame,
                persist=True,
                tracker=self.tracker,
                classes=[PERSON_CLASS, *VEHICLE_CLASSES],
                verbose=False,
            )[0]

            boxes = results.boxes
            if boxes is None or boxes.id is None:
                detections = []
            else:
                detections = [
                    (int(track_id), int(box.cls[0]), float(box.conf[0]),
                     [round(float(v), 1) for v in box.xyxy[0]])
                    for box, track_id in zip(boxes, boxes.id)]

            detections = drop_duplicate_vehicles(drop_duplicate_people(detections))
            people_now = self._learn_from_frame(
                frame, frame_number, frame_time, detections, tracks,
                min_conf=min_conf, min_vehicle_size=min_vehicle_size,
                min_colour_size=min_colour_size, min_make_size=min_make_size,
                min_sharpness=min_sharpness, classify_every=classify_every,
                min_person_height=min_person_height, min_face_px=min_face_px,
                keep_crops=bool(crops_dir), cut_off_weight=0.0)

            # Check for weapons even with nobody in frame, sometimes the gun
            # is the only thing the camera caught.
            if self.weapons is not None and (sampled - 1) % weapon_every == 0:
                self.weapons.add_frame(frame, frame_number, frame_time, people_now)

            # We report "most people at once" instead of counting track IDs,
            # because someone who walks behind a pole often comes back with a
            # new ID and would get counted twice.
            if len(people_now) > most_people:
                most_people, most_people_time = len(people_now), frame_time
                if crops_dir:
                    peak_frame = _boxed(frame, [box for _, box in people_now])

        cap.release()
        return self._finish(tracks, min_frames, min_answer_share, most_people,
                            most_people_time, peak_frame, crops_dir,
                            min_plate_reads=2, weapon_min_frames=3,
                            min_make_share=min_make_share)

    def process_image(self, image_path, min_conf=0.4, min_vehicle_size=60,
                      min_sharpness=15, min_answer_share=0.4,
                      min_colour_size=30, min_make_size=120, min_make_share=0.6,
                      min_person_height=80, min_face_px=36, crops_dir=None):
        """Same as process_video but for a single photo.

        A few things work differently since we only get one look:
          - no tracking, objects are just numbered
          - one clean plate read is enough (videos need two to agree). The
            per-character confidence checks still throw out blurry plates.
          - cars touching the edge still count at half weight, because in a
            close-up the car usually fills the whole photo
        """
        frame = load_image(image_path)
        results = self.model.predict(
            frame,
            conf=min_conf,
            classes=[PERSON_CLASS, *VEHICLE_CLASSES],
            verbose=False,
        )[0]

        detections = []
        if results.boxes is not None:
            for number, box in enumerate(results.boxes, start=1):
                detections.append((number, int(box.cls[0]), float(box.conf[0]),
                                   [round(float(v), 1) for v in box.xyxy[0]]))

        tracks = {}
        if self.weapons is not None:
            self.weapons.reset()
        detections = drop_duplicate_vehicles(drop_duplicate_people(detections))
        people_now = self._learn_from_frame(
            frame, 1, 0.0, detections, tracks,
            min_conf=min_conf, min_vehicle_size=min_vehicle_size,
                min_colour_size=min_colour_size, min_make_size=min_make_size,
            min_sharpness=min_sharpness, classify_every=1,
            min_person_height=min_person_height, min_face_px=min_face_px,
            keep_crops=bool(crops_dir), cut_off_weight=0.5)

        if self.weapons is not None:
            self.weapons.add_image(frame, people_now)
        peak_frame = (_boxed(frame, [box for _, box in people_now])
                      if crops_dir and people_now else None)
        return self._finish(tracks, 1, min_answer_share, len(people_now),
                            0.0 if people_now else None, peak_frame, crops_dir,
                            min_plate_reads=1, weapon_min_frames=1,
                            min_make_share=min_make_share)

    def _learn_from_frame(self, frame, frame_number, frame_time, detections,
                          tracks, min_conf, min_vehicle_size, min_sharpness,
                          min_colour_size, min_make_size,
                          classify_every, min_person_height, min_face_px,
                          keep_crops, cut_off_weight):
        """Fold one frame's detections into the per-track records.

        cut_off_weight is how much an edge-touching vehicle counts for
        make/colour (0 means ignore it). Returns the people in this frame as
        [(track_id, box)], which we need for the head count and for working
        out who's holding a weapon.
        """
        people_now = []
        for track_id, class_id, confidence, xyxy in detections:
            if confidence < min_conf:
                continue
            is_vehicle = class_id in VEHICLE_CLASSES
            if class_id == PERSON_CLASS:
                people_now.append((track_id, xyxy))

            if track_id not in tracks:
                tracks[track_id] = {
                    "detection_type": "vehicle" if is_vehicle else "person",
                    "class_votes": Counter(),
                    "make_scores": None,        # running sum of probabilities
                    "colour_scores": None,      # same
                    "colour_votes": Counter(),  # k-means fallback only
                    "views_used": 0,
                    "make_views": 0,
                    "plate_votes": PlateVotes() if PlateVotes else None,
                    "person": None if is_vehicle else PersonRecord(),
                    "first_seen_seconds": frame_time,
                    "frames_seen": 0,
                    "best_score": -1.0,
                    "best_crop": None,
                    "views": [],                # (quality, time, crop), best first
                }
            t = tracks[track_id]
            t["frames_seen"] += 1
            t["last_seen_seconds"] = frame_time
            t["class_votes"][VEHICLE_CLASSES.get(class_id, "person")] += confidence

            width, height = xyxy[2] - xyxy[0], xyxy[3] - xyxy[1]
            cut_off = touches_edge(xyxy, frame)

            # Remember the best view we've had (big, confident, not cut off)
            score = width * height * confidence * (0.5 if cut_off else 1.0)
            if score > t["best_score"]:
                t.update(best_score=score, confidence=round(confidence, 3),
                         bounding_box=xyxy, frame_number=frame_number,
                         frame_time_seconds=frame_time)
                if is_vehicle and keep_crops:
                    crop = crop_box(frame, xyxy)
                    t["best_crop"] = None if crop is None else crop.copy()

            # The expensive stuff below only runs every Nth sighting
            if t["frames_seen"] % classify_every != 1 and classify_every > 1:
                continue

            if not is_vehicle:
                if height >= min_person_height and t["person"] is not None:
                    t["person"].add_view(frame, xyxy, confidence, frame_time,
                                         self.faces, min_face_px=min_face_px,
                                         pose=self.pose)
                    # Unlike cars, we keep cut-off people (at half weight).
                    # Phone footage is full of people half out of frame.
                    crop = crop_box(frame, xyxy)
                    if crop is not None:
                        quality = height * confidence * min(1.0, sharpness(crop) / 150)
                        _keep_view(t, quality * (0.5 if cut_off else 1.0), frame_time, crop)
                continue

            # Vehicles. Colour, plate and make each need a different amount of
            # detail, so each has its own size cut-off. Colour still works on
            # small blurry cars; make really doesn't, since badges and grilles
            # turn into a few pixels of mush.
            smallest = min(width, height)
            if smallest < min_colour_size:
                continue
            crop = crop_box(frame, xyxy)
            if crop is None:
                continue
            sharp = sharpness(crop)
            sharp_enough = sharp >= min_sharpness

            # Plates are fine on cut-off cars, as long as the plate is in shot
            if self.plates is not None and smallest >= min_vehicle_size and sharp_enough:
                for read in self.plates.read(crop):
                    t["plate_votes"].add(read)

            if cut_off and cut_off_weight <= 0:
                continue
            edge_factor = cut_off_weight if cut_off else 1.0
            _keep_view(t, view_quality(xyxy, sharp, confidence) * edge_factor, frame_time, crop)

            if self.classifier is not None:
                # Blur barely affects colour, so pretend it's perfectly sharp
                colour_weight = view_quality(xyxy, 150, confidence) * edge_factor
                colour_p = self.classifier.colour_probabilities(crop) * colour_weight
                t["colour_scores"] = colour_p if t["colour_scores"] is None else t["colour_scores"] + colour_p
                t["views_used"] += 1
                if smallest >= min_make_size and sharp_enough:
                    make_weight = view_quality(xyxy, sharp, confidence) * edge_factor
                    make_p = self.classifier.make_probabilities(crop) * make_weight
                    t["make_scores"] = make_p if t["make_scores"] is None else t["make_scores"] + make_p
                    t["make_views"] += 1
            else:
                colour = vehicle_colour(frame, xyxy, min_size=min_colour_size)
                if colour:
                    t["colour_votes"][colour] += edge_factor
                    t["views_used"] += 1
        return people_now

    def _finish(self, tracks, min_frames, min_answer_share, most_people,
                most_people_time, peak_frame, crops_dir, min_plate_reads,
                weapon_min_frames, min_make_share=0.6):
        """Wrap up a run: build the results, fingerprints, stats and crops."""
        objects = self._summarise(tracks, min_frames, min_answer_share,
                                  min_plate_reads, min_make_share)
        for obj in objects:
            views = _spread_views(tracks[obj["track_id"]]["views"])
            obj["appearance"] = (self.appearance.describe([c for _, _, c in views])
                                 if self.appearance is not None and views else None)
        self.last_run_stats = {
            "max_people_at_once": most_people,
            "max_people_time_seconds": most_people_time,
            "weapon_detection": self.weapons is not None,
        }
        if self.weapons is not None:
            objects += self.weapons.results(weapon_min_frames, min_answer_share,
                                            crops_dir)
        if crops_dir:
            self._save_crops(tracks, objects, crops_dir)
            if peak_frame is not None:
                path = Path(crops_dir) / "people_peak.png"
                cv2.imwrite(str(path), peak_frame)
                self.last_run_stats["people_peak_frame_path"] = str(path)
        return objects

    @staticmethod
    def _save_crops(tracks, objects, crops_dir):
        """Write the crops to disk and put their paths on each result.

        PNG rather than JPEG so plates and faces don't get compression smear.
        """
        folder = Path(crops_dir)
        folder.mkdir(parents=True, exist_ok=True)
        for obj in objects:
            if obj["detection_type"] == "weapon":
                continue                  # weapons.py saves its own
            t = tracks[obj["track_id"]]
            # A couple of extra shots from other moments for the crops grid
            views = _spread_views(t["views"], count=3)
            extras = []
            if obj["detection_type"] == "person":
                person_path, face_path = t["person"].save_images(folder, obj["track_id"])
                if person_path:
                    obj["person_crop_path"], obj["face_crop_path"] = person_path, face_path
                    face_time = t["person"].best_face_time or 0.0
                    # don't repeat the moment the face shot came from
                    views = [v for v in views if abs(v[1] - face_time) >= 0.4]
                elif views:
                    # No usable face, but the clothing is still worth a picture
                    path = folder / f"person_{obj['track_id']}.png"
                    cv2.imwrite(str(path), views[0][2])
                    obj["person_crop_path"], obj["face_crop_path"] = str(path), None
                    views = views[1:]
                else:
                    views = []
                for number, (_, _, crop) in enumerate(views[:2], start=2):
                    path = folder / f"person_{obj['track_id']}_{number}.png"
                    cv2.imwrite(str(path), crop)
                    extras.append(str(path))
                obj["extra_crop_paths"] = extras
                continue
            crop = t.get("best_crop")
            if crop is not None:
                path = folder / f"vehicle_{obj['track_id']}.png"
                cv2.imwrite(str(path), crop)
                obj["crop_path"] = str(path)
            for number, (_, _, view) in enumerate(views[1:3], start=2):
                path = folder / f"vehicle_{obj['track_id']}_{number}.png"
                cv2.imwrite(str(path), view)
                extras.append(str(path))
            obj["extra_crop_paths"] = extras
            votes = t.get("plate_votes")
            if votes is not None and votes.best_image is not None:
                obj["plate_crop_path"] = votes.save_best_image(
                    folder / f"plate_{obj['track_id']}.png")

    def _summarise(self, tracks, min_frames, min_answer_share=0.4,
                   min_plate_reads=2, min_make_share=0.6):
        """Turn the raw track records into the result dicts."""
        objects = []
        for track_id, t in sorted(tracks.items()):
            if t["frames_seen"] < min_frames:
                continue  # blips like this are nearly always false positives

            result = {
                "track_id": track_id,
                "detection_type": t["detection_type"],
                "class_name": t["class_votes"].most_common(1)[0][0],
                "confidence": t["confidence"],
                # box/frame/time are all from the best view we had
                "bounding_box": t["bounding_box"],
                "frame_number": t["frame_number"],
                "frame_time_seconds": t["frame_time_seconds"],
                "first_seen_seconds": t["first_seen_seconds"],
                "last_seen_seconds": t["last_seen_seconds"],
                "frames_seen": t["frames_seen"],
                "model_version": self.model_version,
            }

            if t["detection_type"] == "person":
                result.update(t["person"].result(min_share=min_answer_share))

            if t["detection_type"] == "vehicle":
                # *_confidence is how much of the weighted evidence the winner
                # got (0.9 = views agree, 0.4 = it's a toss-up). *_top3 keeps
                # the runners-up, e.g. {"Toyota": 0.82, "Lexus": 0.1, ...}
                if self.classifier is not None:
                    make, make_share, make_top = _soft_winner(
                        t["make_scores"], self.classifier.make_labels)
                    colour, colour_share, colour_top = _soft_winner(
                        t["colour_scores"], self.classifier.colour_labels)
                else:
                    make, make_share, make_top = None, 0.0, {}
                    colour, colour_share = _count_winner(t["colour_votes"])
                    colour_top = {k: round(v / sum(t["colour_votes"].values()), 2)
                                  for k, v in t["colour_votes"].most_common(3)}
                # Not enough agreement -> None, but the guesses stay in top3
                if make_share < max(min_answer_share, min_make_share):
                    make = None
                if colour_share < min_answer_share:
                    colour = None
                plate = (t["plate_votes"].result(min_reads=min_plate_reads,
                                                 min_share=min_answer_share)
                         if t["plate_votes"] is not None else
                         {"plate": None, "plate_confidence": 0.0, "plate_reads": 0,
                          "plate_format": None, "plate_top3": {}})
                result.update(plate)
                result.update(
                    make=make,
                    make_confidence=make_share,
                    make_top3=make_top,
                    colour=colour,
                    colour_confidence=colour_share,
                    colour_top3=colour_top,
                    views_used=t["views_used"],
                    make_views=t["make_views"],     # 0 means it was always too far away
                )

            objects.append(result)
        return objects
