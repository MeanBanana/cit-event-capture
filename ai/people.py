"""
people.py - what the pipeline records about each PERSON, for investigators.

For every tracked person this collects, over all the frames they appear in:
  * their clearest picture, but ONLY if their face is visible and big enough
    for an investigator to look at (roughly: within ~5 m on normal phone video)
  * their upper and lower clothing colours (AI-suggested, voted over frames)

Privacy (POPIA): this module only FINDS where a face is in the picture so we
can choose a good frame. It never identifies anyone - no face recognition, no
comparing faces, no face data stored apart from the picture an investigator
reviews. Every person is only a "possible suspect" until an investigator on
the case decides (see database/README.md, "Suspects and POPIA").

Face finding uses YuNet (MIT licence, from OpenCV's model zoo,
https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet),
saved in people_models/.

How big is "big enough"?  Distance can't be measured from one camera, but
the face's size in pixels is a good stand-in. On normal 1080p phone video a
face about 5 metres away is roughly 35-40 px tall, so the default is 36 px.
Shared (WhatsApp) videos are shrunk, so faces there are often too small:
that is correct - a 15 px face is no use to an investigator.
"""

from collections import Counter
from pathlib import Path

import cv2
import numpy as np

from colours import dominant_colour

MODELS = Path(__file__).parent / "people_models"
FACE_MODEL = MODELS / "face_detection_yunet_2026may.onnx"

# For clothing, "silver" means grey.
_CLOTHING_NAMES = {"silver": "grey"}


def _sharpness(bgr):
    """Variance of the Laplacian (higher = sharper), on a fixed-size copy."""
    grey = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    grey = cv2.resize(grey, (112, 112))
    return float(cv2.Laplacian(grey, cv2.CV_64F).var())


def _clip(box, frame):
    """Box [x1, y1, x2, y2] as whole pixels inside the frame, or None."""
    height, width = frame.shape[:2]
    x1, y1, x2, y2 = (int(round(v)) for v in box)
    x1, y1, x2, y2 = max(0, x1), max(0, y1), min(width, x2), min(height, y2)
    return (x1, y1, x2, y2) if x2 > x1 and y2 > y1 else None


class FaceFinder:
    """Finds faces (where they are, how big, how sure). Never identifies."""

    def __init__(self, model=FACE_MODEL, min_score=0.8):
        self.detector = cv2.FaceDetectorYN.create(str(model), "", (320, 320), min_score)

    def biggest_face(self, bgr):
        """(x, y, w, h, score) of the biggest face in the picture, or None."""
        h, w = bgr.shape[:2]
        if h < 20 or w < 20:
            return None
        self.detector.setInputSize((w, h))
        _, faces = self.detector.detect(bgr)
        if faces is None or len(faces) == 0:
            return None
        best = max(faces, key=lambda f: f[2] * f[3])
        return int(best[0]), int(best[1]), int(best[2]), int(best[3]), float(best[-1])


def clothing_colours(frame, box):
    """(upper colour, lower colour) of a person in box [x1, y1, x2, y2].

    Upper = torso (20-50% down the box), lower = legs (55-90% down), using the
    middle half of the width so background and arms count less. Either can be
    None if that part is too small or off the picture.
    """
    clipped = _clip(box, frame)
    if clipped is None:
        return None, None
    x1, y1, x2, y2 = clipped
    w, h = x2 - x1, y2 - y1
    left, right = x1 + int(w * 0.25), x1 + int(w * 0.75)
    upper = frame[y1 + int(h * 0.20):y1 + int(h * 0.50), left:right]
    lower = frame[y1 + int(h * 0.55):y1 + int(h * 0.90), left:right]
    up, low = dominant_colour(upper), dominant_colour(lower)
    return _CLOTHING_NAMES.get(up, up), _CLOTHING_NAMES.get(low, low)


class PersonRecord:
    """Everything collected about one tracked person across frames."""

    def __init__(self):
        self.upper_votes = Counter()     # colour -> weight
        self.lower_votes = Counter()
        self.clothing_views = 0
        self.face_views = 0              # frames where a big-enough face was seen
        self.biggest_face_px = 0
        self._best_quality = -1.0
        self.best_person_image = None    # whole person, clearest face frame
        self.best_face_image = None      # head close-up from that frame
        self.best_face_time = None

    def add_view(self, frame, box, confidence, frame_time, faces,
                 min_face_px=36, min_face_sharpness=40):
        """Learn from one frame where this person is clearly visible."""
        clipped = _clip(box, frame)
        if clipped is None:
            return
        x1, y1, x2, y2 = clipped
        height = y2 - y1

        # --- clothing: bigger, surer views count more
        weight = min(1.0, height / 300) * confidence
        upper, lower = clothing_colours(frame, (x1, y1, x2, y2))
        if upper:
            self.upper_votes[upper] += weight
        if lower:
            self.lower_votes[lower] += weight
        if upper or lower:
            self.clothing_views += 1

        # --- face: look in the top half of the person (where the head is)
        if faces is None:
            return
        head_area = frame[y1:y1 + max(1, int(height * 0.5)), x1:x2]
        face = faces.biggest_face(head_area)
        if face is None:
            return
        fx, fy, fw, fh, score = face
        self.biggest_face_px = max(self.biggest_face_px, fh)
        if fh < min_face_px:
            return                       # too far away to be useful
        fx, fy = fx + x1, fy + y1        # back to whole-frame coordinates

        # head close-up: the face plus a margin around it
        face_box = _clip((fx - fw * 0.6, fy - fh * 0.6, fx + fw * 1.6, fy + fh * 1.5), frame)
        if face_box is None:
            return
        face_image = frame[face_box[1]:face_box[3], face_box[0]:face_box[2]]
        sharp = _sharpness(face_image)
        if sharp < min_face_sharpness:
            return                       # face too blurry to recognise by eye
        self.face_views += 1

        # keep the best frame: biggest, surest, sharpest face
        quality = fh * score * min(1.0, sharp / 150)
        if quality > self._best_quality:
            self._best_quality = quality
            margin_x, margin_y = (x2 - x1) * 0.08, height * 0.05
            person_box = _clip((x1 - margin_x, y1 - margin_y, x2 + margin_x, y2 + margin_y), frame)
            self.best_person_image = frame[person_box[1]:person_box[3],
                                           person_box[0]:person_box[2]].copy()
            self.best_face_image = face_image.copy()
            self.best_face_time = frame_time

    def result(self, min_share=0.4):
        """The person's summary (clothing colours are AI suggestions)."""
        def winner(votes):
            total = sum(votes.values())
            if total <= 0:
                return None, 0.0, {}
            ranked = votes.most_common(3)
            top3 = {c: round(w / total, 2) for c, w in ranked}
            colour, w = ranked[0]
            share = round(w / total, 2)
            return (colour if share >= min_share else None), share, top3

        upper, upper_share, upper_top = winner(self.upper_votes)
        lower, lower_share, lower_top = winner(self.lower_votes)
        return {
            "face_visible": self.best_face_image is not None,
            "face_size_px": self.biggest_face_px,     # biggest face seen (0 = none)
            "face_views": self.face_views,
            "best_face_time_seconds": self.best_face_time,
            "upper_clothing": upper,                  # None = unsure / not seen
            "upper_clothing_confidence": upper_share,
            "upper_clothing_top3": upper_top,
            "lower_clothing": lower,
            "lower_clothing_confidence": lower_share,
            "lower_clothing_top3": lower_top,
            "clothing_views": self.clothing_views,
        }

    def save_images(self, folder, track_id):
        """Saves person_<id>.png (whole person) and face_<id>.png (close-up,
        enlarged to at least 200 px tall). Returns the two paths, or Nones."""
        if self.best_person_image is None:
            return None, None
        folder = Path(folder)
        person_path = folder / f"person_{track_id}.png"
        face_path = folder / f"face_{track_id}.png"
        cv2.imwrite(str(person_path), self.best_person_image)
        face = self.best_face_image
        if face.shape[0] < 200:
            scale = 200 / face.shape[0]
            face = cv2.resize(face, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC)
        cv2.imwrite(str(face_path), face)
        return str(person_path), str(face_path)
