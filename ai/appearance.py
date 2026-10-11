"""
appearance.py - a "fingerprint" of how a person or vehicle LOOKS, so the case
system can suggest "this person in submission 5 is probably Person 2".

Two crops of the same person are never the same pixels, so pictures can't be
compared directly. Instead each tracked person / vehicle gets:
  * embedding    512 numbers from a small image model (YOLO26s-cls, the
                 classification version of the detector we already use). Similar
                 looking people give similar numbers.
  * colour_hist  96 numbers: the colours of the top half and the bottom half
                 of the body (clothing), from up to 6 of the clearest views.
similarity(a, b) combines them: 0.7 x embedding + 0.3 x colours (cosine,
roughly 0-1). Measured on our test clips (people):
    same person (two different moments of one track)   0.85 - 0.95
    different people                                    typically ~0.6, highest 0.79
so the case matcher uses: >= 0.88 and the clothing agrees -> same person;
0.78 - 0.88 -> "Is this Person 2?" for the admin; below -> a different person.
That calibration is from a handful of clips - treat matches as suggestions.

Vehicles get the same fingerprint, but for cars it does NOT tell two white
hatchbacks apart (same-model cars scored as high as the same car), so the
matcher links vehicles by plate, make and colour and only uses this as a
tie-breaker.

Privacy (POPIA): this describes clothing and overall look, like a witness
would ("black top, blue jeans"). It is NOT face recognition: no face data is
used or stored, and a match is only ever a suggestion an admin confirms.

The model file (yolo26s-cls.pt, 13 MB) downloads automatically the first time,
like yolo26s.pt.
"""

import cv2
import numpy as np

MODEL = "yolo26s-cls.pt"
EMBED_SIZE = 224
MAX_VIEWS = 6
WEIGHT_EMBEDDING, WEIGHT_COLOURS = 0.7, 0.3

PERSON_SAME, PERSON_MAYBE = 0.88, 0.78       # see the top of this file


def _square(crop):
    """Pad to a square (grey border) so the model sees the whole person
    instead of a centre cut of a tall box."""
    h, w = crop.shape[:2]
    side = max(h, w)
    out = np.full((side, side, 3), 114, np.uint8)
    top, left = (side - h) // 2, (side - w) // 2
    out[top:top + h, left:left + w] = crop
    return out


def colour_hist(crops):
    """96 numbers: hue x saturation of the top and bottom half (clothing),
    averaged over the views and normalised."""
    hists = []
    for crop in crops:
        h, w = crop.shape[:2]
        body = crop[int(h * 0.15):int(h * 0.9), int(w * 0.2):int(w * 0.8)]
        if body.size == 0:
            continue
        hsv = cv2.cvtColor(body, cv2.COLOR_BGR2HSV)
        half = hsv.shape[0] // 2
        parts = []
        for part in (hsv[:half], hsv[half:]):
            hist = cv2.calcHist([part], [0, 1], None, [12, 4], [0, 180, 0, 256]).flatten()
            parts.append(hist / (hist.sum() + 1e-6))
        hists.append(np.concatenate(parts))
    if not hists:
        return None
    mean = np.mean(hists, axis=0)
    return mean / (np.linalg.norm(mean) + 1e-9)


class AppearanceModel:
    """Loads the image model once; describe() makes a fingerprint."""

    def __init__(self, model=MODEL):
        from ultralytics import YOLO
        self.model = YOLO(model)
        self.version = f"{model.rsplit('.', 1)[0]}+hsv"

    def describe(self, crops):
        """Fingerprint of one tracked object from a few of its crops (BGR).
        Returns {"embedding": [...512], "colour_hist": [...96], "views": n,
        "model": ...} or None if there is nothing usable."""
        crops = [c for c in crops if c is not None and c.size and min(c.shape[:2]) >= 16]
        crops = crops[:MAX_VIEWS]
        if not crops:
            return None
        results = self.model.embed([_square(c) for c in crops], imgsz=EMBED_SIZE, verbose=False)
        vectors = np.stack([r.cpu().numpy().astype(np.float32) for r in results])
        vectors /= np.linalg.norm(vectors, axis=1, keepdims=True) + 1e-9
        mean = vectors.mean(axis=0)
        mean /= np.linalg.norm(mean) + 1e-9
        hist = colour_hist(crops)
        return {
            "embedding": [round(float(v), 4) for v in mean],
            "colour_hist": None if hist is None else [round(float(v), 4) for v in hist],
            "views": len(crops),
            "model": self.version,
        }


def _cosine(a, b):
    if a is None or b is None:
        return None
    a, b = np.asarray(a, np.float32), np.asarray(b, np.float32)
    return float(a @ b / ((np.linalg.norm(a) * np.linalg.norm(b)) + 1e-9))


def similarity(a, b):
    """How alike two fingerprints are (about 0-1), or None if one is missing."""
    if not a or not b:
        return None
    emb = _cosine(a.get("embedding"), b.get("embedding"))
    col = _cosine(a.get("colour_hist"), b.get("colour_hist"))
    if emb is None:
        return col
    if col is None:
        return emb
    return WEIGHT_EMBEDDING * emb + WEIGHT_COLOURS * col
