"""
Finds and reads number plates, then combines reads from lots of frames into
one answer.

Built on FastALPR (MIT, https://github.com/ankandrew/fast-alpr), which gives
us a small YOLOv9 plate finder plus fast-plate-ocr's "global" reader. The
reader gives a confidence per character, which turns out to be really
useful. Models download themselves on first use.

A single frame of a moving car is usually a bit blurry or angled and the
reader gets a character or two wrong, so we vote across frames like we do
for make and colour.

We're deliberately strict here. A wrong plate could put an innocent driver
in the frame, so unclear reads get thrown away and we only report a plate
when several frames agree.

SA isn't one of the reader's training countries, but our plates use the same
characters and similar fonts so it copes fine on clear plates. We give reads
that match an SA format a bit more weight, and fix the usual look-alike
mistakes (O/0, I/1, B/8 etc) when that turns a read into a valid SA plate.
"""

import re
from itertools import combinations

import cv2
import numpy as np

# Common SA plate formats, written without spaces/dashes. Not exhaustive,
# there are plenty of old and special formats this won't match.
SA_FORMATS = [
    ("Gauteng",       r"^[A-Z]{2}\d{2}[A-Z]{2}GP$"),   # AB12CDGP, current style
    ("Gauteng",       r"^[A-Z]{3}\d{3}GP$"),           # ABC123GP, older style
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

# characters the OCR mixes up on blurry plates
LOOK_ALIKES = [("0", "O"), ("1", "I"), ("8", "B"), ("5", "S"), ("2", "Z"), ("6", "G")]


def normalise(text):
    """'ca 123-456' -> 'CA123456'"""
    return re.sub(r"[^A-Z0-9]", "", (text or "").upper())


def sa_format(plate):
    """Name of the SA format the plate matches, e.g. 'Gauteng'."""
    for name, pattern in _SA_PATTERNS:
        if pattern.match(plate):
            return name
    return None


def fix_look_alikes(plate, max_changes=2):
    """Try swapping up to `max_changes` look-alike characters to get a valid
    SA plate, e.g. 'CA12345O' -> 'CA123450'. Returns the original if nothing
    works."""
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
    """Levenshtein distance."""
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


# --- reading a single image

class PlateReader:
    """Finds and reads plates in a crop of a vehicle."""

    def __init__(self,
                 detector_model="yolo-v9-t-384-license-plate-end2end",
                 ocr_model="cct-s-v2-global-model"):
        from fast_alpr import ALPR      # lazy import, fast-alpr is optional
        self.alpr = ALPR(detector_model=detector_model, ocr_model=ocr_model)
        self.version = f"fastalpr-{ocr_model}"

    def read(self, bgr_vehicle_crop, min_plate_conf=0.4,
             min_mean_char_conf=0.75, min_char_conf=0.4):
        """Return the plates we could read clearly.

        Each read is a dict with text (look-alikes already fixed), raw_text,
        char_conf, plate_conf, width and the plate image. We drop anything
        that isn't 4-10 characters, or where any single character or the
        average falls below the confidence thresholds.
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


# --- combining reads for one vehicle

class PlateVotes:
    """All the plate reads for one vehicle, and the logic to pick a winner."""

    def __init__(self):
        self.weights = {}        # plate text -> summed weight
        self.reads = 0
        self.best_image = None
        self._best_weight = -1.0

    def add(self, read):
        # Clear, confident, bigger reads count more, and SA-shaped plates
        # get a 30% bump
        size_factor = min(1.0, read["width"] / 100)
        weight = read["char_conf"] * read["plate_conf"] * max(size_factor, 0.2)
        if sa_format(read["text"]):
            weight *= 1.3
        self.weights[read["text"]] = self.weights.get(read["text"], 0.0) + weight
        self.reads += 1
        if weight > self._best_weight:
            self._best_weight, self.best_image = weight, read["image"]

    def result(self, min_reads=2, min_share=0.4):
        """Pick the plate.

        Reads that are one character apart get lumped together, since the
        weaker one is almost certainly a misread. We only report a plate if
        it was read in at least `min_reads` frames and has `min_share` of
        the weight. Otherwise plate is None, but plate_top3 still has the
        guesses so an investigator can have a look.
        """
        if not self.weights:
            return {"plate": None, "plate_confidence": 0.0, "plate_reads": 0,
                    "plate_format": None, "plate_top3": {}}

        # fold near-duplicates into the strongest read
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
            "plate": reported,
            "plate_confidence": share,
            "plate_reads": self.reads,
            "plate_format": sa_format(best) if reported else None,
            "plate_top3": top3,
        }

    def save_best_image(self, path, scale=3):
        """Save the best plate crop, blown up 3x so it's easy to check by eye."""
        if self.best_image is None or self.best_image.size == 0:
            return None
        big = cv2.resize(self.best_image, None, fx=scale, fy=scale,
                         interpolation=cv2.INTER_CUBIC)
        cv2.imwrite(str(path), big)
        return str(path)
