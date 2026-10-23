"""
Appearance fingerprints, so the case system can say things like "this person
in submission 5 looks like Person 2".

You can't compare crops pixel by pixel, so each person/vehicle gets:
  - embedding: 512 numbers from yolo26s-cls. Similar-looking things end up
    with similar numbers.
  - colour_hist: 96 numbers describing the colours of the top and bottom
    half (basically their clothes).

similarity() mixes the two 70/30. On our test clips the same person scored
0.85-0.95 and different people mostly around 0.6 (worst case 0.79), which is
where the 0.88 / 0.78 cut-offs below come from. That's only a handful of
clips though, so treat a match as a hint, not a fact.

For cars this is pretty useless: two white hatchbacks of the same model
score as high as the same car twice. The matcher goes by plate/make/colour
for vehicles and only uses this to break ties.

On POPIA: this is "black top, blue jeans", the kind of thing a witness would
say. It's not face recognition, no face data goes in, and an admin always has
to confirm a match.
"""

import cv2
import numpy as np

MODEL = "yolo26s-cls.pt"
EMBED_SIZE = 224
MAX_VIEWS = 6
WEIGHT_EMBEDDING, WEIGHT_COLOURS = 0.7, 0.3

PERSON_SAME, PERSON_MAYBE = 0.88, 0.78       # see the docstring up top


def _square(crop):
    """Pad to a square with grey so a tall person doesn't get their head and
    feet cropped off by the model's centre crop."""
    h, w = crop.shape[:2]
    side = max(h, w)
    out = np.full((side, side, 3), 114, np.uint8)
    top, left = (side - h) // 2, (side - w) // 2
    out[top:top + h, left:left + w] = crop
    return out


def colour_hist(crops):
    """Hue/saturation histograms for the top and bottom half, averaged over
    all the crops."""
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
    """Wraps the embedding model so we only load it once."""

    def __init__(self, model=MODEL):
        from ultralytics import YOLO
        self.model = YOLO(model)
        self.version = f"{model.rsplit('.', 1)[0]}+hsv"

    def describe(self, crops):
        """Build a fingerprint from a few BGR crops of one object.
        Returns None if none of the crops are usable."""
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
    """Roughly 0-1. None if either side has no fingerprint."""
    if not a or not b:
        return None
    emb = _cosine(a.get("embedding"), b.get("embedding"))
    col = _cosine(a.get("colour_hist"), b.get("colour_hist"))
    if emb is None:
        return col
    if col is None:
        return emb
    return WEIGHT_EMBEDDING * emb + WEIGHT_COLOURS * col
