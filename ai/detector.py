"""
detector.py - finds vehicles, people and weapons in a video (or a single
photo), follows each one from frame to frame, and works out each vehicle's
MAKE (brand) and COLOUR. Photos: see process_image. Weapons: see weapons.py.

How it works, in plain English:

  1. YOLO26s looks at every frame and draws boxes around cars, trucks,
     people, ...
  2. The TRACKER (TrackTrack, settings in argus_tracker.yaml) matches each
     box with the boxes in earlier frames, so the same car keeps the same
     number ("track_id") while it is on screen - even if the camera shakes
     or the car is hidden for a moment.
  3. Every few frames, each clearly visible vehicle is cut out of the frame
     and two small pretrained models (Spectrico, see vehicle_classifier.py)
     give a probability for every make and every colour.
  4. These are added up over all the frames ("soft voting"), and frames
     with a better view count for more:
        * a bigger (closer) vehicle counts more than a small, far one
        * a sharp picture counts more than a blurry one
        * a box YOLO is sure about counts more than a doubtful one
     Very blurry pictures, tiny vehicles and vehicles cut off by the edge of
     the picture don't count at all.
  5. On the same good views, the NUMBER PLATE is found and read
     (plate_reader.py). Only clear readings count, and readings that fit a
     South African plate format count more.
  6. For PEOPLE (see people.py): clothing colours (upper / lower) are voted
     over frames, and the clearest frame where their FACE is visible and big
     enough for an investigator (about 5 m on normal phone video) is saved.
     Faces are only found, never identified (POPIA). The most people visible
     at the same time is also counted - a safer number than counting IDs,
     because a person hidden for a while can come back with a new ID.
  7. Each tracked object becomes ONE result. A vehicle's make, colour and
     plate are the answers with the most (weighted) support. Answers with
     too little agreement are reported as None ("unsure").
  8. Each person and vehicle also gets an APPEARANCE fingerprint from its
     clearest few views (appearance.py) and up to 3 pictures from different
     moments, so the case system can suggest the same person / vehicle in
     another submission.

If the Spectrico models can't be loaded (e.g. MNN isn't installed), the
detector still runs: colour falls back to our own k-means method
(vehicle_colour below) and make is left empty.

The output matches what the database's `detection` + `vehicledetail` tables
want: one row per real object (see database/README.md, "The AI pipeline").
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
except ImportError as error:          # MNN not installed
    VehicleClassifier = None
    _CLASSIFIER_ERROR = error

    def sharpness(bgr_crop):          # same measure, without the models
        grey = cv2.resize(cv2.cvtColor(bgr_crop, cv2.COLOR_BGR2GRAY), (224, 224))
        return float(cv2.Laplacian(grey, cv2.CV_64F).var())

try:
    from weapons import WeaponFinder
except ImportError as error:          # weapons.py missing
    WeaponFinder = None
    _WEAPON_IMPORT_ERROR = error

try:
    from appearance import AppearanceModel
except ImportError as error:          # appearance.py missing
    AppearanceModel = None
    _APPEARANCE_IMPORT_ERROR = error

try:
    from plate_reader import PlateReader, PlateVotes
except ImportError as error:          # plate_reader.py missing
    PlateReader, PlateVotes = None, None
    _PLATE_IMPORT_ERROR = error

HERE = Path(__file__).parent

# Detector: YOLO26 small. Bigger and newer than yolov8n, so it finds distant
# and partly hidden vehicles and people much more reliably (it is slower).
# The file downloads by itself the first time (about 20 MB).
# Faster but less accurate: "yolo26n.pt". More accurate but slower: "yolo26m.pt".
DEFAULT_MODEL = "yolo26s.pt"

# Tracker settings (TrackTrack with camera-motion compensation, tuned to keep
# a vehicle's ID while it is briefly hidden). See argus_tracker.yaml.
TRACKER_CONFIG = str(HERE / "argus_tracker.yaml")

# YOLO's class numbers (COCO dataset) that we care about
VEHICLE_CLASSES = {2: "car", 3: "motorcycle", 5: "bus", 7: "truck"}
PERSON_CLASS = 0



# ---------------------------------------------------------------------------
# Colour (fallback for vehicles when the Spectrico colour model isn't loaded)
# ---------------------------------------------------------------------------

def vehicle_colour(frame, box, min_size=40):
    """The main colour of the vehicle inside `box` [x1, y1, x2, y2].

    Returns a colour word, or None if the box is too small to judge.
    """
    height, width = frame.shape[:2]
    # Box corners as whole pixels, kept inside the picture.
    x1, y1, x2, y2 = (int(round(v)) for v in box)
    x1, y1 = max(0, x1), max(0, y1)
    x2, y2 = min(width, x2), min(height, y2)
    if x2 - x1 < min_size or y2 - y1 < min_size:
        return None  # too far away / too small: the colour would be a guess

    car = frame[y1:y2, x1:x2]
    h, w = car.shape[:2]

    # Use the middle part of the box: mostly body panels. The edges are
    # usually road, sky or other cars; the top is often windows, the bottom
    # tyres and shadow.
    body = car[int(h * 0.30):int(h * 0.80), int(w * 0.15):int(w * 0.85)]
    return dominant_colour(body)       # k-means, see colours.py


# ---------------------------------------------------------------------------
# Detector + tracker
# ---------------------------------------------------------------------------

def crop_box(frame, box, margin=0.05):
    """The part of the frame inside box [x1, y1, x2, y2], plus a small margin
    so the whole vehicle is in the picture. Returns None if it's empty."""
    height, width = frame.shape[:2]
    x1, y1, x2, y2 = box
    mx, my = (x2 - x1) * margin, (y2 - y1) * margin
    x1, y1 = max(0, int(x1 - mx)), max(0, int(y1 - my))
    x2, y2 = min(width, int(x2 + mx)), min(height, int(y2 + my))
    if x2 <= x1 or y2 <= y1:
        return None
    return frame[y1:y2, x1:x2]


def touches_edge(box, frame, gap=3):
    """True if the box touches the edge of the picture: the vehicle is
    probably cut off, and half a car often gets the wrong make."""
    height, width = frame.shape[:2]
    x1, y1, x2, y2 = box
    return x1 <= gap or y1 <= gap or x2 >= width - gap or y2 >= height - gap


def view_quality(box, sharp, confidence):
    """How much one frame's answer should count (0-1).

    size:       vehicles 224 px or bigger (the models' picture size) count
                fully; smaller ones count less.
    sharpness:  150+ counts fully; blurrier counts less.
    confidence: how sure YOLO was that this is a vehicle.
    """
    width, height = box[2] - box[0], box[3] - box[1]
    size_factor = min(1.0, min(width, height) / 224)
    sharp_factor = min(1.0, sharp / 150)
    return size_factor * sharp_factor * confidence


def _soft_winner(scores, labels):
    """From summed probabilities: (best label, its share of the total,
    top 3 as {label: share}). (None, 0.0, {}) if nothing was scored."""
    total = float(scores.sum()) if scores is not None else 0.0
    if total <= 0:
        return None, 0.0, {}
    order = np.argsort(scores)[::-1][:3]
    top3 = {labels[i]: round(float(scores[i]) / total, 2) for i in order
            if scores[i] / total >= 0.01}
    best = int(order[0])
    return labels[best], round(float(scores[best]) / total, 2), top3


def _count_winner(votes):
    """(answer, share of votes) from a Counter, or (None, 0.0) if empty."""
    if not votes:
        return None, 0.0
    answer, count = votes.most_common(1)[0]
    return answer, round(count / sum(votes.values()), 2)


# Photo types process_image / main.py accept. HEIC/HEIF (iPhone photos)
# need the pillow-heif package (in requirements.txt).
IMAGE_TYPES = {".jpg", ".jpeg", ".png", ".bmp", ".webp", ".tif", ".tiff",
               ".gif", ".heic", ".heif"}


def load_image(path):
    """Reads a photo as a BGR picture (OpenCV's format), the right way up.

    Phone photos are often stored sideways with an EXIF note saying "rotate
    me"; Pillow's exif_transpose applies that note, otherwise people and cars
    would be lying on their side and YOLO would miss them. Transparent PNGs
    are put on white. GIFs: the first frame is used.
    Falls back to OpenCV if Pillow can't read the file.
    """
    path = Path(path)
    if not path.is_file():
        raise FileNotFoundError(f"Could not find image: {path}")
    try:
        from PIL import Image, ImageOps
        try:
            import pillow_heif                  # optional: iPhone HEIC photos
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
        # np.fromfile + imdecode also works with non-English folder names on
        # Windows, where cv2.imread fails.
        data = np.fromfile(str(path), dtype=np.uint8)
        frame = cv2.imdecode(data, cv2.IMREAD_COLOR) if data.size else None
        if frame is None:
            hint = (" - for iPhone HEIC photos run: pip install pillow-heif"
                    if path.suffix.lower() in (".heic", ".heif") else "")
            raise ValueError(f"Could not read image: {path}{hint}") from pil_error
        return frame


def _keep_view(track, quality, frame_time, crop, keep=12):
    """Remember one of the track's clearest views (for its appearance
    fingerprint and extra pictures). Only the `keep` best are held."""
    views = track["views"]
    if len(views) >= keep and quality <= views[-1][0]:
        return
    views.append((quality, frame_time, crop.copy()))
    views.sort(key=lambda v: -v[0])
    del views[keep:]


def _spread_views(views, count=6, min_gap=0.4):
    """The clearest views, at least `min_gap` seconds apart (different
    moments say more than six copies of the same frame)."""
    chosen = []
    for view in views:                    # already clearest first
        if all(abs(view[1] - c[1]) >= min_gap for c in chosen):
            chosen.append(view)
        if len(chosen) == count:
            break
    return chosen


def drop_duplicate_people(detections, inside=0.9, same_height=0.1):
    """Removes a second box around the SAME person.

    The detector sometimes draws two boxes on one person: one tight around
    the body and a wider one that also covers outstretched arms (e.g. aiming
    a rifle). They share the same top and bottom. A real second person
    standing behind someone has a different top/bottom (they look smaller),
    so they are kept.

    detections: [(id, class_id, confidence, [x1, y1, x2, y2]), ...]
    A person box is dropped when it lies at least `inside` (90%) within a
    surer person box AND their tops and bottoms are within `same_height`
    (10%) of the box height of each other.
    """
    people = [d for d in detections if d[1] == PERSON_CLASS]
    others = [d for d in detections if d[1] != PERSON_CLASS]
    kept = []
    for det in sorted(people, key=lambda d: -d[2]):          # surest first
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
    """True if boxes a and b ([x1, y1, x2, y2]) are almost certainly the
    SAME vehicle: they overlap a lot (IoU >= min_iou), or one lies nearly
    all inside the other and they're about the same size. A small car in
    front of a big truck is NOT the same vehicle (very different sizes)."""
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
    """Removes a second box around the SAME vehicle.

    YOLO26 has no cross-class NMS, so a bakkie (pickup) or minibus often
    gets two boxes at once: "car" AND "truck" (or "bus"). Without this the
    summary says "a silver car and a silver truck" for one bakkie. The
    surest box is kept; see same_vehicle for what counts as the same one.

    detections: [(id, class_id, confidence, [x1, y1, x2, y2]), ...]
    """
    vehicles = [d for d in detections if d[1] in VEHICLE_CLASSES]
    others = [d for d in detections if d[1] not in VEHICLE_CLASSES]
    kept = []
    for det in sorted(vehicles, key=lambda d: -d[2]):          # surest first
        if not any(same_vehicle(det[3], k[3], **rules) for k in kept):
            kept.append(det)
    return others + kept


def _drop_duplicate_vehicle_boxes(predictor):
    """Ultralytics callback (on_predict_postprocess_end): removes duplicate
    vehicle boxes from each result BEFORE the tracker sees them, so one
    bakkie never becomes two tracks (one "car", one "truck") in a video.
    Registered in ArgusDetector.__init__, i.e. before track() adds the
    tracker's own callback, so it runs first."""
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
    """A copy of the frame with an orange box around each [x1, y1, x2, y2]."""
    picture = frame.copy()
    for x1, y1, x2, y2 in boxes:
        cv2.rectangle(picture, (int(x1), int(y1)), (int(x2), int(y2)),
                      (0, 165, 255), 2)
    return picture


class ArgusDetector:
    def __init__(self, model_path=DEFAULT_MODEL, tracker=TRACKER_CONFIG):
        # Downloads the YOLO model file the first time.
        self.model = YOLO(model_path)
        # One box per vehicle (a bakkie is not "a car AND a truck"). Added
        # before the first track() call, so it runs before the tracker.
        self.model.add_callback("on_predict_postprocess_end", _drop_duplicate_vehicle_boxes)
        self.model_name = Path(model_path).stem      # e.g. "yolo26s"
        self.tracker = tracker

        # Make + colour models. Optional: without them we fall back to
        # k-means colour and no make.
        self.classifier = None
        if VehicleClassifier is None:
            print(f"Make/colour models not available ({_CLASSIFIER_ERROR}). "
                  "Run: pip install MNN. Using basic colour only.")
        else:
            try:
                self.classifier = VehicleClassifier()
            except Exception as error:   # model files missing, etc.
                print(f"Could not load make/colour models ({error}). "
                      "Using basic colour only.")

        # Face finder (people's pictures). Optional: without it, people still
        # get clothing colours but no pictures.
        self.faces = None
        try:
            self.faces = FaceFinder()
        except Exception as error:       # model file missing, etc.
            print(f"Face finding not available ({error}). "
                  "People will have no pictures.")

        # Body joints (shoulders / hips / knees) for clothing colours: where
        # the top and the bottom are, and whether they're bare skin. Optional:
        # without it clothing falls back to fixed parts of the box (much less
        # reliable in close-ups). yolo26s-pose.pt downloads itself once.
        self.pose = None
        try:
            self.pose = PoseFinder(str(Path(__file__).parent / "yolo26s-pose.pt"))
        except Exception as error:
            print(f"Body pose model not available ({error}). "
                  "Clothing colours will be less reliable.")

        # Weapon finder (handgun / long gun / knife / machete). Optional.
        self.weapons = None
        if WeaponFinder is None:
            print(f"Weapon detection not available ({_WEAPON_IMPORT_ERROR}).")
        else:
            try:
                self.weapons = WeaponFinder()     # own tracker settings
            except Exception as error:   # model download failed, etc.
                print(f"Weapon detection not available ({error}).")

        # Appearance fingerprints (for matching across submissions). Optional.
        self.appearance = None
        if AppearanceModel is None:
            print(f"Appearance matching not available ({_APPEARANCE_IMPORT_ERROR}).")
        else:
            try:
                self.appearance = AppearanceModel()
            except Exception as error:   # model download failed, etc.
                print(f"Appearance matching not available ({error}).")

        # Stats about the last video (e.g. most people at once).
        self.last_run_stats = {}

        # Number plate reader. Optional too: without it, plates are skipped.
        self.plates = None
        if PlateReader is None:
            print(f"Plate reading not available ({_PLATE_IMPORT_ERROR}).")
        else:
            try:
                self.plates = PlateReader()
            except Exception as error:   # fast-alpr not installed, no internet
                print(f"Plate reading not available ({error}). "
                      "Run: pip install -r requirements.txt")

    @property
    def model_version(self):
        """Which models produced the results (saved with each detection)."""
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
        """Finds, tracks and identifies the vehicles, people and weapons in a video.

        sample_every      look at every Nth frame. 1 = every frame (best
                          tracking); 2 = about twice as fast.
        min_conf          ignore boxes YOLO is less than this sure about.
        min_frames        drop objects seen in fewer frames than this
                          (usually a mistake that lasted a moment).
        min_vehicle_size  only read plates when the vehicle box is at least
                          this many pixels wide and high.
        min_colour_size   judge colour from this size (pixels) up.
        min_make_size     judge make only from this size up (badges and
                          grilles need detail).
        min_make_share    report a make only with at least this share of the
                          evidence (stricter than colour); otherwise
                          "unsure", guesses kept in make_top3.
        min_sharpness     skip pictures blurrier than this for make / colour
                          (see vehicle_classifier.sharpness).
        classify_every    judge each vehicle's make / colour on every Nth
                          frame it appears in. Neighbouring frames look almost
                          the same, so this saves a lot of time for very
                          little accuracy.
        min_answer_share  report a make / colour only if it has at least this
                          share (0-1) of the evidence; otherwise it is None
                          ("unsure") and only the top-3 guesses are kept. Better
                          an honest "unknown" than a confident-looking wrong
                          answer that sends investigators after the wrong car.
        min_person_height only judge a person's clothing / face when their box
                          is at least this many pixels tall.
        min_face_px       a person's picture is only saved if their face is
                          at least this many pixels tall in some frame (about
                          5 m away on 1080p phone video).
        weapon_every      look for weapons on every Nth sampled frame (the
                          weapon model is a second model, so this halves its
                          cost; 1 = every frame, finds brief glimpses better).
        crops_dir         if given, save PNG pictures there: each vehicle's
                          clearest view, plate close-ups, and each person
                          whose face is visible (person_<id>.png + face_<id>.png),
                          plus people_peak.png (the frame with the most people).

        Returns a list with ONE dictionary per tracked object.
        """
        # Fresh tracker for every video: when several files are processed in
        # one run (a submission), IDs must not carry over from the last video.
        self.model.predictor = None
        cap = cv2.VideoCapture(str(video_path))
        if not cap.isOpened():
            raise FileNotFoundError(f"Could not open video: {video_path}")

        fps = cap.get(cv2.CAP_PROP_FPS) or 25
        tracks = {}        # track_id -> everything we learn about that object
        frame_number = 0
        most_people, most_people_time, peak_frame = 0, None, None
        if self.weapons is not None:
            self.weapons.reset()
        sampled = 0

        while True:
            ok, frame = cap.read()
            if not ok:
                break                     # end of the video
            frame_number += 1
            if frame_number % sample_every != 0:
                continue                  # skip frames we don't sample

            frame_time = round(frame_number / fps, 2)
            sampled += 1

            # track() = detect + match with earlier frames.
            # persist=True tells it this frame follows the previous one.
            results = self.model.track(
                frame,
                persist=True,
                tracker=self.tracker,
                classes=[PERSON_CLASS, *VEHICLE_CLASSES],  # only what we need
                verbose=False,
            )[0]

            boxes = results.boxes
            if boxes is None or boxes.id is None:
                detections = []           # nothing being tracked in this frame
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

            # Weapons (a separate model with its own tracker). Even frames
            # with no person are checked: the gun may be all that's visible.
            if self.weapons is not None and (sampled - 1) % weapon_every == 0:
                self.weapons.add_frame(frame, frame_number, frame_time, people_now)

            # Most people visible at the same time (the safe people count).
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
        """The same as process_video, for ONE photo (JPEG, PNG, WebP, ...;
        see load_image).

        Differences, because there is only one view of everything:
          * no tracking - each object found just gets its own number
          * a plate is reported from ONE clear reading (a video needs 2
            frames to agree); the strict per-character confidence filters
            still apply, so blurry plates are still rejected
          * a vehicle touching the edge of the photo is still judged (at half
            weight) - in a close-up photo the car often fills the picture
          * max_people_at_once = the number of people in the photo
        Settings mean the same as in process_video.
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
        """Adds what one picture shows to each object's record in `tracks`.

        detections      [(track_id, class_id, confidence, [x1, y1, x2, y2]), ...]
        cut_off_weight  how much a vehicle touching the picture's edge counts
                        for make / colour (0 = not at all).
        Returns [(track_id, box)] for the people in this picture (for the
        people count and for linking weapons to the person holding them).
        """
        people_now = []
        for track_id, class_id, confidence, xyxy in detections:
            if confidence < min_conf:
                continue
            is_vehicle = class_id in VEHICLE_CLASSES
            if class_id == PERSON_CLASS:
                people_now.append((track_id, xyxy))

            # First time we see this object: start its record.
            if track_id not in tracks:
                tracks[track_id] = {
                    "detection_type": "vehicle" if is_vehicle else "person",
                    "class_votes": Counter(),   # car / truck / ... per frame
                    "make_scores": None,        # summed make probabilities
                    "colour_scores": None,      # summed colour probabilities
                    "colour_votes": Counter(),  # only for the k-means fallback
                    "views_used": 0,            # frames that judged colour
                    "make_views": 0,            # frames close/sharp enough for make
                    "plate_votes": PlateVotes() if PlateVotes else None,
                    "person": None if is_vehicle else PersonRecord(),
                    "first_seen_seconds": frame_time,
                    "frames_seen": 0,
                    "best_score": -1.0,
                    "best_crop": None,
                    "views": [],                # [(quality, time, crop)] clearest few
                }
            t = tracks[track_id]
            t["frames_seen"] += 1
            t["last_seen_seconds"] = frame_time
            # car / truck / bus: bigger, surer boxes count more
            t["class_votes"][VEHICLE_CLASSES.get(class_id, "person")] += confidence

            width, height = xyxy[2] - xyxy[0], xyxy[3] - xyxy[1]
            cut_off = touches_edge(xyxy, frame)

            # Keep the clearest view: biggest, surest, not cut off.
            score = width * height * confidence * (0.5 if cut_off else 1.0)
            if score > t["best_score"]:
                t.update(best_score=score, confidence=round(confidence, 3),
                         bounding_box=xyxy, frame_number=frame_number,
                         frame_time_seconds=frame_time)
                if is_vehicle and keep_crops:
                    crop = crop_box(frame, xyxy)
                    t["best_crop"] = None if crop is None else crop.copy()

            # ---- only good views, every Nth appearance
            if t["frames_seen"] % classify_every != 1 and classify_every > 1:
                continue

            # ---- people: clothing colours + face picture
            if not is_vehicle:
                if height >= min_person_height and t["person"] is not None:
                    t["person"].add_view(frame, xyxy, confidence, frame_time,
                                         self.faces, min_face_px=min_face_px,
                                         pose=self.pose)
                    # (cut-off views too, at half weight: in close-up phone
                    # footage people are often partly out of the picture)
                    crop = crop_box(frame, xyxy)
                    if crop is not None:
                        quality = height * confidence * min(1.0, sharpness(crop) / 150)
                        _keep_view(t, quality * (0.5 if cut_off else 1.0), frame_time, crop)
                continue

            # ---- vehicles: colour, plate, make - each needs a different
            # amount of detail, so each has its own minimum size:
            #   colour  >= min_colour_size (30 px): a colour survives blur and
            #           small size, so far-away cars still get one
            #   plate   >= min_vehicle_size (60 px) and sharp
            #   make    >= min_make_size (120 px) and sharp: badges, grilles
            #           and lights are only a few blurry pixels on smaller cars,
            #           and a confident WRONG make is worse than "unknown"
            smallest = min(width, height)
            if smallest < min_colour_size:
                continue
            crop = crop_box(frame, xyxy)
            if crop is None:
                continue
            sharp = sharpness(crop)
            sharp_enough = sharp >= min_sharpness

            # Number plate: also fine for a car cut off by the edge, as
            # long as the plate itself is in the picture.
            if self.plates is not None and smallest >= min_vehicle_size and sharp_enough:
                for read in self.plates.read(crop):
                    t["plate_votes"].add(read)

            if cut_off and cut_off_weight <= 0:
                continue              # half a car: make/colour unreliable
            edge_factor = cut_off_weight if cut_off else 1.0
            _keep_view(t, view_quality(xyxy, sharp, confidence) * edge_factor, frame_time, crop)

            if self.classifier is not None:
                # colour: blur doesn't matter much, so no sharpness penalty
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
                colour = vehicle_colour(frame, xyxy, min_size=min_colour_size)   # k-means fallback
                if colour:
                    t["colour_votes"][colour] += edge_factor
                    t["views_used"] += 1
        return people_now

    def _finish(self, tracks, min_frames, min_answer_share, most_people,
                most_people_time, peak_frame, crops_dir, min_plate_reads,
                weapon_min_frames, min_make_share=0.6):
        """Final list of objects + run stats + saved pictures."""
        objects = self._summarise(tracks, min_frames, min_answer_share,
                                  min_plate_reads, min_make_share)
        for obj in objects:              # appearance fingerprints (people, vehicles)
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
        """Saves each vehicle's clearest picture (vehicle_<id>.png) and its
        clearest plate picture, enlarged (plate_<id>.png), and adds the paths.
        PNG is lossless: no compression smudging on plates, faces or paint."""
        folder = Path(crops_dir)
        folder.mkdir(parents=True, exist_ok=True)
        for obj in objects:
            if obj["detection_type"] == "weapon":
                continue                  # weapons save their own (weapons.py)
            t = tracks[obj["track_id"]]
            # up to 2 more pictures from other moments (for the crops grid)
            views = _spread_views(t["views"], count=3)
            extras = []
            if obj["detection_type"] == "person":
                person_path, face_path = t["person"].save_images(folder, obj["track_id"])
                if person_path:
                    obj["person_crop_path"], obj["face_crop_path"] = person_path, face_path
                    face_time = t["person"].best_face_time or 0.0
                    views = [v for v in views if abs(v[1] - face_time) >= 0.4]   # not the same moment
                elif views:
                    # no clear face: still keep the clearest body view (the
                    # clothing is evidence too); face_crop_path stays empty
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
        """Turns the per-object records into the final list."""
        objects = []
        for track_id, t in sorted(tracks.items()):
            if t["frames_seen"] < min_frames:
                continue  # probably a false detection

            result = {
                "track_id": track_id,
                "detection_type": t["detection_type"],
                # most likely class, e.g. a "car" that was once called "truck"
                "class_name": t["class_votes"].most_common(1)[0][0],
                "confidence": t["confidence"],
                "bounding_box": t["bounding_box"],          # clearest view
                "frame_number": t["frame_number"],          # of that view
                "frame_time_seconds": t["frame_time_seconds"],
                "first_seen_seconds": t["first_seen_seconds"],
                "last_seen_seconds": t["last_seen_seconds"],
                "frames_seen": t["frames_seen"],
                "model_version": self.model_version,
            }

            if t["detection_type"] == "person":
                result.update(t["person"].result(min_share=min_answer_share))

            if t["detection_type"] == "vehicle":
                # *_confidence = the winner's share of all the (weighted)
                # evidence: 0.9 = the views agree, 0.4 = mixed (be careful).
                # *_top3 = the closest alternatives, e.g.
                #          {"Toyota": 0.82, "Lexus": 0.1, "Daihatsu": 0.03}
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
                # Too little agreement: say "unsure" (None), keep the guesses.
                # make needs MORE agreement than colour: a wrong brand in a
                # report sends investigators after the wrong car
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
                    make=make,                      # None = no good view / unsure
                    make_confidence=make_share,
                    make_top3=make_top,
                    colour=colour,
                    colour_confidence=colour_share,
                    colour_top3=colour_top,
                    views_used=t["views_used"],     # frames that judged colour
                    make_views=t["make_views"],     # frames close enough for make (0 = too far)
                )

            objects.append(result)
        return objects
