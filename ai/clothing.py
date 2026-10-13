"""
clothing.py - what a person is wearing: the colour of their top and bottom,
or "none" (shown as "no clothing") when that part of the body is bare skin.

  1. A pose model finds the body's joints (shoulders, hips, knees). The TOP
     is the torso between shoulders and hips; the BOTTOM is the thighs
     between hips and knees. A part whose joints aren't visible isn't judged
     at all (no guessing from grass or a car behind the person).
  2. Skin pixels are found (matched to the person's own face colour when
     the face is visible, otherwise a general skin-colour rule). Mostly
     skin = "none" (no shirt / bare legs); otherwise skin (arms, hands) is
     left out before the colour is named.
  3. The remaining pixels are grouped (k-means) and named in the CIELAB
     colour space - which matches how people see colour much better than
     the old HSV hue rules, which turned dark, noisy pixels into "red" or
     "purple" and skin into "orange".

Limits (colour only, no clothing-segmentation model): without a visible
face or bare forearm, darker skin can't be told apart from brown clothing,
so a shirtless person seen only from behind may get a colour instead of
"no clothing". Votes over many frames smooth out single bad frames.
"""

import cv2
import numpy as np

NONE = "none"          # the stored value for bare skin


def clothing_word(value):
    """How a stored clothing value reads: "black", "no clothing", "unsure"."""
    return "no clothing" if value == NONE else (value or "unsure")


# COCO keypoints
NOSE, L_EYE, R_EYE = 0, 1, 2
L_SHOULDER, R_SHOULDER, L_HIP, R_HIP, L_KNEE, R_KNEE = 5, 6, 11, 12, 13, 14

# Colour names: several reference swatches (sRGB) per name, so e.g. both
# bright and dark blue are "blue". The nearest swatch in CIELAB wins.
SWATCHES = {
    "black":  [(15, 15, 15), (35, 35, 38), (45, 42, 40)],
    "grey":   [(80, 80, 80), (115, 115, 118), (150, 150, 150), (95, 100, 105)],
    "white":  [(200, 200, 200), (230, 230, 230), (250, 250, 250), (205, 210, 220)],
    "navy":   [(25, 30, 60), (35, 45, 85), (30, 40, 70)],
    "blue":   [(40, 80, 170), (60, 100, 160), (30, 60, 140), (75, 105, 150), (100, 140, 200)],
    "light blue": [(140, 175, 215), (170, 200, 230), (120, 150, 185)],
    "red":    [(190, 30, 35), (150, 20, 30), (220, 50, 50), (110, 20, 30)],
    "pink":   [(235, 150, 175), (210, 100, 140), (245, 190, 200)],
    "orange": [(240, 120, 30), (220, 90, 30), (250, 150, 60)],
    "yellow": [(240, 220, 50), (220, 200, 80), (250, 235, 120), (200, 230, 60)],
    "green":  [(40, 130, 60), (30, 90, 40), (90, 160, 80), (70, 90, 45), (110, 120, 60)],
    "beige":  [(215, 195, 160), (190, 170, 130), (170, 150, 110)],
    "brown":  [(110, 70, 40), (80, 55, 35), (140, 95, 60)],
    "purple": [(110, 60, 140), (80, 40, 110), (150, 100, 180)],
}


def _lab(rgb_list):
    arr = np.uint8([[c[::-1] for c in rgb_list]])            # RGB -> BGR
    return cv2.cvtColor(arr.astype(np.float32) / 255, cv2.COLOR_BGR2LAB)[0]


_NAMES = [n for n, cs in SWATCHES.items() for _ in cs]
_REF = np.vstack([_lab(cs) for cs in SWATCHES.values()])


def lab_of(bgr_pixels):
    """N x 3 uint8 BGR -> N x 3 CIELAB (L 0-100)."""
    px = bgr_pixels.reshape(-1, 1, 3).astype(np.float32) / 255
    return cv2.cvtColor(px, cv2.COLOR_BGR2LAB).reshape(-1, 3)


_CHROMATIC = np.array([n not in ("black", "grey", "white") for n in _NAMES])


def name_lab(lab):
    """Colour name for one CIELAB colour. Colourless ones by lightness
    (clothes in shadow / sun vary a lot: black in daylight is often L 20-30,
    a white shirt in shade L 70-80 and slightly blue); real colours by the
    nearest reference swatch."""
    L, a, b = (float(v) for v in lab)
    chroma = float(np.hypot(a, b))
    if chroma < 12 or (L < 30 and chroma < 16):
        return "black" if L < 32 else "grey" if L < 68 else "white"
    if L >= 72 and chroma < 24:
        return "white"
    d = np.linalg.norm(_REF - lab, axis=1)
    d[~_CHROMATIC] = np.inf
    return _NAMES[int(np.argmin(d))]


def generic_skin(bgr_pixels):
    """True for pixels with a skin-like colour (any skin tone, roughly).
    Strict on purpose: vivid orange / red clothing (safety vests!) is more
    saturated than skin and must not count as skin."""
    px = bgr_pixels.reshape(-1, 1, 3)
    ycc = cv2.cvtColor(px, cv2.COLOR_BGR2YCrCb).reshape(-1, 3).astype(int)
    hsv = cv2.cvtColor(px, cv2.COLOR_BGR2HSV).reshape(-1, 3).astype(int)
    lab = lab_of(bgr_pixels)
    chroma = np.hypot(lab[:, 1], lab[:, 2])
    hue = np.degrees(np.arctan2(lab[:, 2], lab[:, 1]))
    y, cr, cb = ycc[:, 0], ycc[:, 1], ycc[:, 2]
    return ((cr >= 135) & (cr <= 168) & (cb >= 80) & (cb <= 130) & (y >= 35)
            & (hsv[:, 1] <= 165) & (chroma >= 8) & (chroma <= 34)
            & (hue >= 25) & (hue <= 80))


def matches(bgr_pixels, ref_lab):
    """True for pixels with the same colour as ref_lab (the person's skin).
    Light changes skin a lot between face and body (sun, shade, the
    camera), mostly in brightness and strength of colour, much less in hue -
    so: a close colour, or the same hue with a similar strength."""
    lab = lab_of(bgr_pixels)
    ab, ref_ab = lab[:, 1:], ref_lab[1:]
    chroma, ref_chroma = np.hypot(ab[:, 0], ab[:, 1]), float(np.hypot(*ref_ab))
    hue = np.degrees(np.arctan2(ab[:, 1], ab[:, 0]))
    ref_hue = float(np.degrees(np.arctan2(ref_ab[1], ref_ab[0])))
    hue_diff = np.abs((hue - ref_hue + 180) % 360 - 180)
    close = np.linalg.norm(ab - ref_ab, axis=1) < 10
    same_hue = ((hue_diff < 18) & (chroma > ref_chroma * 0.55)
                & (chroma < ref_chroma * 1.45))
    # skin always has some colour: grey / black / white cloth never matches
    return (close | same_hue) & (chroma > 7) & (np.abs(lab[:, 0] - ref_lab[0]) < 35)


def plausible_skin(lab):
    """Could this CIELAB colour be skin at all (any tone, normal light)?
    Rejects a face sample spoilt by deep shadow, a cap's shade, sunglasses or
    a strong colour cast - better no reference than a wrong one."""
    L, a, b = (float(v) for v in lab)
    chroma = float(np.hypot(a, b))
    hue = float(np.degrees(np.arctan2(b, a)))
    return 12 <= L <= 92 and 8 <= chroma <= 55 and 15 <= hue <= 85


def skin_reference(frame, face_box=None, kp=None, min_conf=0.5):
    """The person's own skin colour (CIELAB): from the middle of the face
    when it's visible, else from a bare forearm (elbow -> wrist), else None.
    face_box = (x, y, w, h) in frame pixels."""
    if face_box is not None:
        # The face finder is sure this is a face, so its middle (cheeks,
        # nose) is skin whatever the tone: no general skin rule needed,
        # which fails for darker skin. Very dark (sunglasses, nostrils) and
        # glare pixels are left out.
        x, y, w, h = face_box
        patch = frame[max(0, y + int(h * 0.45)):y + int(h * 0.75),
                      max(0, x + int(w * 0.25)):x + int(w * 0.75)].reshape(-1, 3)
        if len(patch) >= 30:
            lab = lab_of(patch)
            keep = (lab[:, 0] > 12) & (lab[:, 0] < 92)
            if keep.mean() >= 0.5:
                ref = np.median(lab[keep], axis=0)
                if plausible_skin(ref):
                    return ref
    if kp is not None:
        for elbow, wrist in ((7, 9), (8, 10)):
            if kp[elbow][2] < min_conf or kp[wrist][2] < min_conf:
                continue
            a, b = kp[elbow][:2], kp[wrist][:2]
            length = float(np.linalg.norm(b - a))
            if length < 12:
                continue
            m = np.zeros(frame.shape[:2], np.uint8)
            cv2.line(m, tuple(np.int32(a + (b - a) * 0.2)), tuple(np.int32(a + (b - a) * 0.8)),
                     1, max(2, int(length * 0.15)))
            px = frame[m.astype(bool)]
            skin = generic_skin(px)
            if len(px) >= 30 and skin.mean() >= 0.6:         # a bare forearm
                ref = np.median(lab_of(px[skin]), axis=0)
                if plausible_skin(ref):
                    return ref
    return None


def skin_mask(bgr_pixels, skin_lab=None):
    """True for skin pixels: matched to the person's own skin colour when
    known (works for every skin tone), otherwise the strict general rule."""
    if skin_lab is None:
        return generic_skin(bgr_pixels)
    return matches(bgr_pixels, skin_lab)


def _quad_mask(shape, pts):
    m = np.zeros(shape[:2], np.uint8)
    cv2.fillConvexPoly(m, np.int32(pts), 1)
    return m.astype(bool)


def _shrink(pts, factor):
    """Pull a polygon's corners towards its centre (keep away from edges /
    background / arms)."""
    pts = np.float32(pts)
    c = pts.mean(axis=0)
    return c + (pts - c) * factor


def _band(a, b, start, end, width):
    """A strip along the line a -> b (from start to end, as fractions of
    the way) that is width pixels wide."""
    a, b = np.float32(a), np.float32(b)
    d = b - a
    n = np.float32([-d[1], d[0]]) / (np.linalg.norm(d) + 1e-6) * width / 2
    p, q = a + d * start, a + d * end
    return [p + n, p - n, q - n, q + n]


def body_regions(kp, box=None, min_conf=0.5):
    """(torso polygon, thighs polygon) from 17 COCO keypoints [x, y, conf]
    in frame pixels; either None when that part isn't visible.

    Best case both shoulders and hips (front / back view). Otherwise, for
    side views and close-ups: one shoulder + hip on the same side, or just
    the top of the upper arm below a shoulder (the sleeve - or bare skin);
    one hip + knee for the thigh. When the knees aren't visible at all (cut
    off by the picture's edge, a car door ...) the thighs are the part just
    below the hips that is still inside the person's box [x1, y1, x2, y2].
    """
    ok = lambda *ids: all(kp[i][2] >= min_conf for i in ids)
    pt = lambda i: np.float32(kp[i][:2])
    torso = thighs = None

    if ok(L_SHOULDER, R_SHOULDER, L_HIP, R_HIP):
        ls, rs, lh, rh = (pt(i) for i in (L_SHOULDER, R_SHOULDER, L_HIP, R_HIP))
        # a little below the shoulders (neck / collar) to just above the hips
        torso = _shrink([ls + (lh - ls) * 0.12, rs + (rh - rs) * 0.12,
                         rs + (rh - rs) * 0.92, ls + (lh - ls) * 0.92], 0.75)
    else:
        for sho, hip, elbow in ((L_SHOULDER, L_HIP, 7), (R_SHOULDER, R_HIP, 8)):
            if ok(sho, hip):                       # side view: one side's flank
                length = float(np.linalg.norm(pt(hip) - pt(sho)))
                torso = _band(pt(sho), pt(hip), 0.15, 0.85, length * 0.3)
                break
            if ok(sho, elbow):                     # close-up: the sleeve
                length = float(np.linalg.norm(pt(elbow) - pt(sho)))
                if length >= 15:
                    torso = _band(pt(sho), pt(elbow), 0.1, 0.4, length * 0.3)
                    break

    if ok(L_HIP, R_HIP, L_KNEE, R_KNEE):
        lh, rh, lk, rk = (pt(i) for i in (L_HIP, R_HIP, L_KNEE, R_KNEE))
        # upper 2/3 of the thighs (shorts still count as a bottom)
        thighs = _shrink([lh + (lk - lh) * 0.08, rh + (rk - rh) * 0.08,
                          rh + (rk - rh) * 0.66, lh + (lk - lh) * 0.66], 0.8)
    else:
        for hip, knee in ((L_HIP, L_KNEE), (R_HIP, R_KNEE)):
            if ok(hip, knee):                      # side view: one thigh
                length = float(np.linalg.norm(pt(knee) - pt(hip)))
                thighs = _band(pt(hip), pt(knee), 0.1, 0.66, length * 0.3)
                break
        if thighs is None and ok(L_SHOULDER, R_SHOULDER, L_HIP, R_HIP) and box is not None:
            ls, rs, lh, rh = (pt(i) for i in (L_SHOULDER, R_SHOULDER, L_HIP, R_HIP))
            down = np.float32([0.0, np.linalg.norm((lh + rh) / 2 - (ls + rs) / 2) * 0.45])
            hip_y = float(max(lh[1], rh[1]))
            bottom = min(float(box[3]), hip_y + float(down[1]))
            if bottom - hip_y > down[1] * 0.6:     # enough of it is in view
                thighs = _shrink([lh + down * 0.15, rh + down * 0.15,
                                  np.float32([rh[0], bottom]), np.float32([lh[0], bottom])], 0.8)
    return torso, thighs


def describe_region(frame, polygon, skin_lab=None, min_pixels=150,
                    bare_share=0.6):
    """("none", share) for bare skin, (colour, share) for clothing, or
    (None, 0) when there's too little to judge. share = how much of the
    region the answer covers (0-1)."""
    if polygon is None:
        return None, 0.0
    mask = _quad_mask(frame.shape, polygon)
    px = frame[mask]
    if len(px) < min_pixels:
        return None, 0.0
    skin = skin_mask(px, skin_lab)
    if skin.mean() >= bare_share:
        return NONE, float(skin.mean())
    cloth = px[~skin]
    if len(cloth) < min_pixels // 2:
        return None, 0.0
    lab = lab_of(cloth)
    k = 3 if len(lab) >= 60 else 1
    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 10, 1.0)
    _, labels, centres = cv2.kmeans(lab.astype(np.float32), k, None, criteria, 2,
                                    cv2.KMEANS_PP_CENTERS)
    counts = np.bincount(labels.flatten(), minlength=k)
    votes = {}
    for centre, n in zip(centres, counts):
        name = name_lab(centre)
        votes[name] = votes.get(name, 0) + n
    name, n = max(votes.items(), key=lambda kv: kv[1])
    return name, float(n / len(px))


class PoseFinder:
    """Body joints of one person (yolo26s-pose, downloaded by Ultralytics
    the first time)."""

    def __init__(self, weights="yolo26s-pose.pt", device=None):
        from ultralytics import YOLO
        self.model = YOLO(weights)          # downloads itself the first time
        self.device = device

    def keypoints(self, frame, box, pad=0.1):
        """17 x [x, y, conf] in frame pixels for the person in box, or None."""
        h, w = frame.shape[:2]
        x1, y1, x2, y2 = box
        bw, bh = x2 - x1, y2 - y1
        cx1, cy1 = max(0, int(x1 - bw * pad)), max(0, int(y1 - bh * pad))
        cx2, cy2 = min(w, int(x2 + bw * pad)), min(h, int(y2 + bh * pad))
        crop = frame[cy1:cy2, cx1:cx2]
        if crop.size == 0:
            return None
        r = self.model.predict(crop, imgsz=320, conf=0.25, verbose=False,
                               device=self.device)[0]
        if r.keypoints is None or len(r.boxes) == 0:
            return None
        # the person whose box best matches ours
        ours = np.array([x1 - cx1, y1 - cy1, x2 - cx1, y2 - cy1], float)
        boxes = r.boxes.xyxy.cpu().numpy()
        def iou(b):
            ix = max(0, min(b[2], ours[2]) - max(b[0], ours[0]))
            iy = max(0, min(b[3], ours[3]) - max(b[1], ours[1]))
            inter = ix * iy
            return inter / ((b[2]-b[0])*(b[3]-b[1]) + (ours[2]-ours[0])*(ours[3]-ours[1]) - inter + 1e-6)
        best = max(range(len(boxes)), key=lambda i: iou(boxes[i]))
        if iou(boxes[best]) < 0.3:
            return None
        kp = r.keypoints.data[best].cpu().numpy().copy()     # 17 x 3
        kp[:, 0] += cx1
        kp[:, 1] += cy1
        return kp
