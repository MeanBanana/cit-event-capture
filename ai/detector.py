"""
detector.py - finds vehicles and people in a video (or a single photo),
follows each one from frame to frame, and works out each vehicle's MAKE
(brand) and COLOUR. Photos: see process_image.

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

try:
    from vehicle_classifier import VehicleClassifier, sharpness
except ImportError as error:          # MNN not installed
    VehicleClassifier = None
    _CLASSIFIER_ERROR = error

    def sharpness(bgr_crop):          # same measure, without the models
        grey = cv2.resize(cv2.cvtColor(bgr_crop, cv2.COLOR_BGR2GRAY), (224, 224))
        return float(cv2.Laplacian(grey, cv2.CV_64F).var())

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
        return "+".join(parts)

    def process_video(self, video_path, sample_every=1, min_conf=0.4,
                      min_frames=3, min_vehicle_size=60, min_sharpness=15,
                      classify_every=3, min_answer_share=0.4,
                      min_person_height=80, min_face_px=36, crops_dir=None):
        """Finds, tracks and identifies the vehicles and people in a video.

        sample_every      look at every Nth frame. 1 = every frame (best
                          tracking); 2 = about twice as fast.
        min_conf          ignore boxes YOLO is less than this sure about.
        min_frames        drop objects seen in fewer frames than this
                          (usually a mistake that lasted a moment).
        min_vehicle_size  only judge make / colour when the vehicle box is at
                          least this many pixels wide and high.
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
        crops_dir         if given, save PNG pictures there: each vehicle's
                          clearest view, plate close-ups, and each person
                          whose face is visible (person_<id>.png + face_<id>.png),
                          plus people_peak.png (the frame with the most people).

        Returns a list with ONE dictionary per tracked object.
        """
        cap = cv2.VideoCapture(str(video_path))
        if not cap.isOpened():
            raise FileNotFoundError(f"Could not open video: {video_path}")

        fps = cap.get(cv2.CAP_PROP_FPS) or 25
        tracks = {}        # track_id -> everything we learn about that object
        frame_number = 0
        most_people, most_people_time, peak_frame = 0, None, None

        while True:
            ok, frame = cap.read()
            if not ok:
                break                     # end of the video
            frame_number += 1
            if frame_number % sample_every != 0:
                continue                  # skip frames we don't sample

            frame_time = round(frame_number / fps, 2)

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
                continue                  # nothing being tracked in this frame

            detections = [
                (int(track_id), int(box.cls[0]), float(box.conf[0]),
                 [round(float(v), 1) for v in box.xyxy[0]])
                for box, track_id in zip(boxes, boxes.id)]

            people_now = self._learn_from_frame(
                frame, frame_number, frame_time, detections, tracks,
                min_conf=min_conf, min_vehicle_size=min_vehicle_size,
                min_sharpness=min_sharpness, classify_every=classify_every,
                min_person_height=min_person_height, min_face_px=min_face_px,
                keep_crops=bool(crops_dir), cut_off_weight=0.0)

            # Most people visible at the same time (the safe people count).
            if len(people_now) > most_people:
                most_people, most_people_time = len(people_now), frame_time
                if crops_dir:
                    peak_frame = _boxed(frame, people_now)

        cap.release()
        return self._finish(tracks, min_frames, min_answer_share, most_people,
                            most_people_time, peak_frame, crops_dir,
                            min_plate_reads=2)

    def process_image(self, image_path, min_conf=0.4, min_vehicle_size=60,
                      min_sharpness=15, min_answer_share=0.4,
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
        people_now = self._learn_from_frame(
            frame, 1, 0.0, detections, tracks,
            min_conf=min_conf, min_vehicle_size=min_vehicle_size,
            min_sharpness=min_sharpness, classify_every=1,
            min_person_height=min_person_height, min_face_px=min_face_px,
            keep_crops=bool(crops_dir), cut_off_weight=0.5)

        peak_frame = _boxed(frame, people_now) if crops_dir and people_now else None
        return self._finish(tracks, 1, min_answer_share, len(people_now),
                            0.0 if people_now else None, peak_frame, crops_dir,
                            min_plate_reads=1)

    def _learn_from_frame(self, frame, frame_number, frame_time, detections,
                          tracks, min_conf, min_vehicle_size, min_sharpness,
                          classify_every, min_person_height, min_face_px,
                          keep_crops, cut_off_weight):
        """Adds what one picture shows to each object's record in `tracks`.

        detections      [(track_id, class_id, confidence, [x1, y1, x2, y2]), ...]
        cut_off_weight  how much a vehicle touching the picture's edge counts
                        for make / colour (0 = not at all).
        Returns the boxes of the people in this picture (for the people count).
        """
        people_now = []
        for track_id, class_id, confidence, xyxy in detections:
            if confidence < min_conf:
                continue
            is_vehicle = class_id in VEHICLE_CLASSES
            if class_id == PERSON_CLASS:
                people_now.append(xyxy)

            # First time we see this object: start its record.
            if track_id not in tracks:
                tracks[track_id] = {
                    "detection_type": "vehicle" if is_vehicle else "person",
                    "class_votes": Counter(),   # car / truck / ... per frame
                    "make_scores": None,        # summed make probabilities
                    "colour_scores": None,      # summed colour probabilities
                    "colour_votes": Counter(),  # only for the k-means fallback
                    "views_used": 0,            # frames that judged make/colour
                    "plate_votes": PlateVotes() if PlateVotes else None,
                    "person": None if is_vehicle else PersonRecord(),
                    "first_seen_seconds": frame_time,
                    "frames_seen": 0,
                    "best_score": -1.0,
                    "best_crop": None,
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
                                         self.faces, min_face_px=min_face_px)
                continue

            # ---- vehicles: make + colour + plate
            if width < min_vehicle_size or height < min_vehicle_size:
                continue
            crop = crop_box(frame, xyxy)
            if crop is None:
                continue
            sharp = sharpness(crop)
            if sharp < min_sharpness:
                continue              # too blurry to judge

            # Number plate: also fine for a car cut off by the edge, as
            # long as the plate itself is in the picture.
            if self.plates is not None:
                for read in self.plates.read(crop):
                    t["plate_votes"].add(read)

            if cut_off and cut_off_weight <= 0:
                continue              # half a car: make/colour unreliable
            edge_factor = cut_off_weight if cut_off else 1.0

            if self.classifier is not None:
                weight = view_quality(xyxy, sharp, confidence) * edge_factor
                make_p = self.classifier.make_probabilities(crop) * weight
                colour_p = self.classifier.colour_probabilities(crop) * weight
                t["make_scores"] = make_p if t["make_scores"] is None else t["make_scores"] + make_p
                t["colour_scores"] = colour_p if t["colour_scores"] is None else t["colour_scores"] + colour_p
                t["views_used"] += 1
            else:
                colour = vehicle_colour(frame, xyxy)   # k-means fallback
                if colour:
                    t["colour_votes"][colour] += edge_factor
                    t["views_used"] += 1
        return people_now

    def _finish(self, tracks, min_frames, min_answer_share, most_people,
                most_people_time, peak_frame, crops_dir, min_plate_reads):
        """Final list of objects + run stats + saved pictures."""
        objects = self._summarise(tracks, min_frames, min_answer_share,
                                  min_plate_reads)
        self.last_run_stats = {
            "max_people_at_once": most_people,
            "max_people_time_seconds": most_people_time,
        }
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
            t = tracks[obj["track_id"]]
            if obj["detection_type"] == "person":
                person_path, face_path = t["person"].save_images(folder, obj["track_id"])
                if person_path:
                    obj["person_crop_path"], obj["face_crop_path"] = person_path, face_path
                continue
            crop = t.get("best_crop")
            if crop is not None:
                path = folder / f"vehicle_{obj['track_id']}.png"
                cv2.imwrite(str(path), crop)
                obj["crop_path"] = str(path)
            votes = t.get("plate_votes")
            if votes is not None and votes.best_image is not None:
                obj["plate_crop_path"] = votes.save_best_image(
                    folder / f"plate_{obj['track_id']}.png")

    def _summarise(self, tracks, min_frames, min_answer_share=0.4,
                   min_plate_reads=2):
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
                if make_share < min_answer_share:
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
                    views_used=t["views_used"],     # frames that judged make/colour
                )

            objects.append(result)
        return objects
