"""
plate_reader.py - finds the number plate on a vehicle and reads its
characters, then combines the readings from many frames into one answer.

Uses FastALPR (MIT licence, https://github.com/ankandrew/fast-alpr):
  * a small YOLOv9 model that finds plates in a picture, and
  * fast-plate-ocr's "global" model, which reads the characters and gives a
    confidence for EACH character (trained on plates from 65+ countries).
The model files download by themselves the first time (a few MB).

Why combine frames? One frame of a moving car is often blurry or at an
angle, and the reader gets a character or two wrong. Over many frames the
true plate is read most often, so we vote - like make and colour.

Safety first: a wrong plate can send investigators after an innocent
driver, so blurry/unsure readings are thrown away, and a plate is only
reported when several frames agree. Otherwise the answer is "no plate".

South Africa is not in the reader's list of training countries, but SA
plates use the same letters, digits and similar fonts, and it reads them
when the plate is clear enough. To help, readings that match common South
African plate formats get extra weight, and classic look-alike mistakes
(O/0, I/1, B/8, S/5, Z/2, G/6) are fixed when that turns a reading into a
valid SA plate.
"""

import re
from itertools import combinations

import cv2
import numpy as np

# ---------------------------------------------------------------------------
# South African plate formats (common ones; not every special/old format)
# Written without spaces or dashes: "CA 123-456" -> "CA123456".
# ---------------------------------------------------------------------------
SA_FORMATS = [
    ("Gauteng",       r"^[A-Z]{2}\d{2}[A-Z]{2}GP$"),   # AB12CDGP (current)
    ("Gauteng",       r"^[A-Z]{3}\d{3}GP$"),           # ABC123GP (older)
    ("Western Cape",  r"^C[A-Z]{1,2}\d{1,6}$"),        # CA123456, CY12345, CFM1234
    ("KwaZulu-Natal", r"^N[A-Z]{1,2}\d{1,6}$"),        # ND123456, NPN12345
    ("KwaZulu-Natal", r"^[A-Z]{3}\d{3}ZN$"),
    ("Eastern Cape",  r"^[A-Z]{3}\d{3}EC$"),
    ("Free State",    r"^[A-Z]{3}\d{3}FS$"),
    ("Mpumalanga",    r"^[A-Z]{3}\d{3}MP$"),
    ("North West",    r"^[A-Z]{3}\d{3}NW$"),
    ("Northern Cape", r"^[A-Z]{3}\d{3}NC$"),
    ("Limpopo",       r"^[A-Z]{3}\d{3}LP?$"),
    ("Personalised",  r"^[A-Z0-9]{1,7}(GP|WP|ZN|EC|FS|MP|NW|NC|L)$"),
]
_SA_PATTERNS = [(name, re.compile(p)) for name, p in SA_FORMATS]

# Pairs the reader often confuses (they look alike on a blurry plate).
LOOK_ALIKES = [("0", "O"), ("1", "I"), ("8", "B"), ("5", "S"), ("2", "Z"), ("6", "G")]


def normalise(text):
    """'ca 123-456' -> 'CA123456' (capitals, letters and digits only)."""
    return re.sub(r"[^A-Z0-9]", "", (text or "").upper())


def sa_format(plate):
    """Which SA format the plate matches (e.g. 'Gauteng'), or None."""
    for name, pattern in _SA_PATTERNS:
        if pattern.match(plate):
            return name
    return None


def fix_look_alikes(plate, max_changes=2):
    """If the plate isn't a valid SA plate but swapping up to `max_changes`
    look-alike characters makes it one, return the fixed plate.
    E.g. 'CA12345O' -> 'CA123450'. Otherwise return it unchanged."""
    if sa_format(plate):
        return plate
    swaps = {}
    for a, b in LOOK_ALIKES:
        swaps[a], swaps[b] = b, a
    positions = [i for i, ch in enumerate(plate) if ch in swaps]
    for n in range(1, max_changes + 1):
        for chosen in combinations(positions, n):
            chars = list(plate)
            for i in chosen:
                chars[i] = swaps[chars[i]]
            candidate = "".join(chars)
            if sa_format(candidate):
                return candidate
    return plate


def _edit_distance(a, b):
    """How many single-character changes turn a into b (Levenshtein)."""
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


# ---------------------------------------------------------------------------
# Reading one picture
# ---------------------------------------------------------------------------

class PlateReader:
    """Finds and reads number plates in a picture of a vehicle."""

    def __init__(self,
                 detector_model="yolo-v9-t-384-license-plate-end2end",
                 ocr_model="cct-s-v2-global-model"):
        from fast_alpr import ALPR      # imported here so it stays optional
        self.alpr = ALPR(detector_model=detector_model, ocr_model=ocr_model)
        self.version = f"fastalpr-{ocr_model}"

    def read(self, bgr_vehicle_crop, min_plate_conf=0.4,
             min_mean_char_conf=0.75, min_char_conf=0.4):
        """Plates in the picture that were read CLEARLY. Each is a dict:
            text        e.g. 'CA123456' (look-alikes fixed if that makes it SA)
            raw_text    what the reader actually said
            char_conf   average confidence over the characters (0-1)
            plate_conf  how sure the finder was that it's a plate (0-1)
            width       plate width in pixels (bigger = more readable)
            image       the plate picture (for saving / checking by eye)
        Unclear readings are left out: any character under min_char_conf, an
        average under min_mean_char_conf, or not 4-10 characters long.
        """
        reads = []
        for result in self.alpr.predict(bgr_vehicle_crop):
            ocr, det = result.ocr, result.detection
            if ocr is None or det.confidence < min_plate_conf:
                continue
            raw = normalise(ocr.text)
            confs = [float(c) for c in (ocr.confidence or [])][:len(raw)] or [0.0]
            if not 4 <= len(raw) <= 10:
                continue
            if min(confs) < min_char_conf or np.mean(confs) < min_mean_char_conf:
                continue
            box = det.bounding_box
            x1, y1 = max(0, box.x1), max(0, box.y1)
            x2 = min(bgr_vehicle_crop.shape[1], box.x2)
            y2 = min(bgr_vehicle_crop.shape[0], box.y2)
            reads.append({
                "text": fix_look_alikes(raw),
                "raw_text": raw,
                "char_conf": float(np.mean(confs)),
                "plate_conf": float(det.confidence),
                "width": x2 - x1,
                "image": bgr_vehicle_crop[y1:y2, x1:x2].copy(),
            })
        return reads


# ---------------------------------------------------------------------------
# Combining many frames for one vehicle
# ---------------------------------------------------------------------------

class PlateVotes:
    """Collects one vehicle's plate readings and picks the answer."""

    def __init__(self):
        self.weights = {}        # plate text -> total weight
        self.reads = 0
        self.best_image = None   # clearest plate picture
        self._best_weight = -1.0

    def add(self, read):
        # Clear, confident, big readings count more. Readings that fit a
        # South African format count 30% more.
        size_factor = min(1.0, read["width"] / 100)
        weight = read["char_conf"] * read["plate_conf"] * max(size_factor, 0.2)
        if sa_format(read["text"]):
            weight *= 1.3
        self.weights[read["text"]] = self.weights.get(read["text"], 0.0) + weight
        self.reads += 1
        if weight > self._best_weight:
            self._best_weight, self.best_image = weight, read["image"]

    def result(self, min_reads=2, min_share=0.4):
        """{plate, plate_confidence, plate_reads, plate_format, plate_top3}.

        Readings one character apart are treated as the same plate (the
        weaker one is a misread). The plate is only given if it was read
        clearly in at least `min_reads` frames and has at least `min_share`
        of the evidence; otherwise plate is None and the guesses stay in
        plate_top3 for an investigator to look at.
        """
        if not self.weights:
            return {"plate": None, "plate_confidence": 0.0, "plate_reads": 0,
                    "plate_format": None, "plate_top3": {}}

        # Merge near-identical readings into the strongest one.
        merged = {}
        for text, weight in sorted(self.weights.items(), key=lambda kv: -kv[1]):
            home = next((m for m in merged
                         if len(m) == len(text) and _edit_distance(m, text) <= 1),
                        None)
            merged[home or text] = merged.get(home or text, 0.0) + weight

        total = sum(merged.values())
        ranked = sorted(merged.items(), key=lambda kv: -kv[1])
        best, best_weight = ranked[0]
        share = round(best_weight / total, 2)
        top3 = {text: round(w / total, 2) for text, w in ranked[:3]}

        reported = best if (self.reads >= min_reads and share >= min_share) else None
        return {
            "plate": reported,                 # None = no clear, agreed plate
            "plate_confidence": share,
            "plate_reads": self.reads,         # frames with a clear reading
            "plate_format": sa_format(best) if reported else None,  # e.g. "Gauteng"
            "plate_top3": top3,
        }

    def save_best_image(self, path, scale=3):
        """Saves the clearest plate picture, enlarged so it's easy to check."""
        if self.best_image is None or self.best_image.size == 0:
            return None
        big = cv2.resize(self.best_image, None, fx=scale, fy=scale,
                         interpolation=cv2.INTER_CUBIC)
        cv2.imwrite(str(path), big)
        return str(path)
