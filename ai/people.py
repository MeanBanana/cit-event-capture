"""
What we keep track of for each person: their best face shot and their
clothing colours.

For the face we want the clearest frame where it's big enough for an
investigator to actually look at (roughly within 5m on normal phone video).
If we never get a decent face, detector.py still saves the best body shot.
Clothing colours are voted across frames, see clothing.py.

POPIA: we only find where a face is so we can pick a good frame. There's no
face recognition, no comparing faces, nothing stored apart from the picture
the investigator looks at. Everyone is just a "possible suspect" until the
investigator on the case says otherwise (database/README.md has more).

Face detection is YuNet from the OpenCV model zoo (MIT licence):
https://github.com/opencv/opencv_zoo/tree/main/models/face_detection_yunet

About the 36px default: we can't measure distance with one camera, but face
height in pixels is a decent stand-in. At 1080p a face 5m away is about
35-40px. WhatsApp shrinks videos so faces there are often too small, and
that's fine, a 15px face is no use to anyone.
"""

from collections import Counter
from pathlib import Path

import cv2
import numpy as np

from clothing import body_regions, describe_region, skin_reference

MODELS = Path(__file__).parent / "people_models"
FACE_MODEL = MODELS / "face_detection_yunet_2026may.onnx"

def _sharpness(bgr):
    """Laplacian variance on a fixed-size copy. Higher is sharper."""
    grey = cv2.cvtColor(bgr, cv2.COLOR_BGR2GRAY)
    grey = cv2.resize(grey, (112, 112))
    return float(cv2.Laplacian(grey, cv2.CV_64F).var())


def _clip(box, frame):
    """Round the box to pixels and clamp it to the frame. None if it's empty."""
    height, width = frame.shape[:2]
    x1, y1, x2, y2 = (int(round(v)) for v in box)
    x1, y1, x2, y2 = max(0, x1), max(0, y1), min(width, x2), min(height, y2)
    return (x1, y1, x2, y2) if x2 > x1 and y2 > y1 else None


class FaceFinder:
    """Finds faces. Only where they are, never who they are."""

    def __init__(self, model=FACE_MODEL, min_score=0.8):
        self.detector = cv2.FaceDetectorYN.create(str(model), "", (320, 320), min_score)

    def biggest_face(self, bgr):
        """Biggest face in the image as (x, y, w, h, score), or None."""
        h, w = bgr.shape[:2]
        if h < 20 or w < 20:
            return None
        self.detector.setInputSize((w, h))
        _, faces = self.detector.detect(bgr)
        if faces is None or len(faces) == 0:
            return None
        best = max(faces, key=lambda f: f[2] * f[3])
        return int(best[0]), int(best[1]), int(best[2]), int(best[3]), float(best[-1])


def clothing_colours(frame, box, pose=None, face_box=None, known_skin=None):
    """Clothing colours for the person in `box`.

    Returns (upper, lower, skin). upper/lower are a colour, "none" for bare
    skin, or None if we can't tell. skin is whatever skin tone we managed to
    sample in this frame. known_skin is what we got from earlier frames, for
    when this one only shows their back.

    Without the pose model we fall back to fixed slices of the box (torso
    22-48% down, legs 58-85%). That's pretty unreliable on close-ups, so it's
    really just a last resort.
    """
    clipped = _clip(box, frame)
    if clipped is None:
        return None, None, None
    kp = pose.keypoints(frame, clipped) if pose is not None else None
    found = skin_reference(frame, face_box, kp)
    skin = found if found is not None else known_skin
    if kp is not None:
        torso, thighs = body_regions(kp, clipped)
        return (describe_region(frame, torso, skin)[0],
                describe_region(frame, thighs, skin)[0], found)
    if pose is not None:
        return None, None, found     # pose model found no body, so don't guess
    x1, y1, x2, y2 = clipped
    w, h = x2 - x1, y2 - y1
    left, right = x1 + w * 0.3, x1 + w * 0.7
    torso = [(left, y1 + h * 0.22), (right, y1 + h * 0.22), (right, y1 + h * 0.48), (left, y1 + h * 0.48)]
    legs = [(left, y1 + h * 0.58), (right, y1 + h * 0.58), (right, y1 + h * 0.85), (left, y1 + h * 0.85)]
    return describe_region(frame, torso, skin)[0], describe_region(frame, legs, skin)[0], found


class PersonRecord:
    """Everything we collect about one tracked person."""

    def __init__(self):
        self.upper_votes = Counter()     # colour -> summed weight
        self.lower_votes = Counter()
        self.clothing_views = 0
        self.skin_seen = []              # CIELAB skin samples, one per frame we got one
        self.face_views = 0
        self.biggest_face_px = 0
        self._best_quality = -1.0
        self.best_person_image = None    # full body from the best face frame
        self.best_face_image = None
        self.best_face_time = None

    def add_view(self, frame, box, confidence, frame_time, faces,
                 min_face_px=36, min_face_sharpness=40, pose=None):
        """Take in one frame of this person. pose is a clothing.PoseFinder, or
        None to use the rough fallback regions."""
        clipped = _clip(box, frame)
        if clipped is None:
            return
        x1, y1, x2, y2 = clipped
        height = y2 - y1

        # the face has to be in the top half of the box
        face = None
        if faces is not None:
            head_area = frame[y1:y1 + max(1, int(height * 0.5)), x1:x2]
            face = faces.biggest_face(head_area)

        # Bigger and more confident views count for more. If we found a face
        # it also tells us their skin tone, which helps spot bare skin.
        weight = min(1.0, height / 300) * confidence
        face_box = None if face is None else (x1 + face[0], y1 + face[1], face[2], face[3])
        known = np.median(self.skin_seen, axis=0) if self.skin_seen else None
        upper, lower, skin = clothing_colours(frame, (x1, y1, x2, y2), pose, face_box, known)
        if skin is not None and len(self.skin_seen) < 50:
            self.skin_seen.append(skin)
        if upper:
            self.upper_votes[upper] += weight
        if lower:
            self.lower_votes[lower] += weight
        if upper or lower:
            self.clothing_views += 1

        if face is None:
            return
        fx, fy, fw, fh, score = face
        self.biggest_face_px = max(self.biggest_face_px, fh)
        if fh < min_face_px:
            return                       # too far away to be useful
        fx, fy = fx + x1, fy + y1        # crop coords -> frame coords

        # head shot = face plus some margin
        face_box = _clip((fx - fw * 0.6, fy - fh * 0.6, fx + fw * 1.6, fy + fh * 1.5), frame)
        if face_box is None:
            return
        face_image = frame[face_box[1]:face_box[3], face_box[0]:face_box[2]]
        sharp = _sharpness(face_image)
        if sharp < min_face_sharpness:
            return                       # too blurry for anyone to recognise
        self.face_views += 1

        # keep whichever frame has the biggest, surest, sharpest face
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
        """Summary dict for this person."""
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
            "face_size_px": self.biggest_face_px,     # 0 means we never saw a face
            "face_views": self.face_views,
            "best_face_time_seconds": self.best_face_time,
            "upper_clothing": upper,                  # colour, "none" for bare skin, or None if unsure
            "upper_clothing_confidence": upper_share,
            "upper_clothing_top3": upper_top,
            "lower_clothing": lower,
            "lower_clothing_confidence": lower_share,
            "lower_clothing_top3": lower_top,
            "clothing_views": self.clothing_views,
        }

    def save_images(self, folder, track_id):
        """Write person_<id>.png and face_<id>.png. The face gets upscaled to at
        least 200px tall so it's easier to look at. Returns both paths."""
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
