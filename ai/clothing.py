"""
Works out what colour someone's top and bottom are, or "none" if that bit
is bare skin.

We use a pose model to find shoulders, hips and knees, so the top is the
torso and the bottom is the thighs. If the joints for a part aren't visible
we just don't judge it, otherwise we end up naming the grass or the car
behind them.

Skin gets masked out first. If we can see their face we match against their
actual skin tone, otherwise we fall back to a generic skin-colour rule. If a
region is mostly skin we call it "none" (shirtless, shorts, etc).

What's left gets clustered and named in CIELAB. We used to do HSV hue rules,
but those turned dark noisy pixels into "red"/"purple" and skin into
"orange", so we switched.

Known gap: with no face or forearm to sample, darker skin and brown clothing
look the same to us, so a shirtless person seen from behind might get a
colour. Voting over lots of frames helps a bit.
"""

import cv2
import numpy as np

NONE = "none"          # what we store for bare skin


def clothing_word(value):
    """Human-readable version of a stored clothing value."""
    return "no clothing" if value == NONE else (value or "unsure")


# COCO keypoints
NOSE, L_EYE, R_EYE = 0, 1, 2
L_SHOULDER, R_SHOULDER, L_HIP, R_HIP, L_KNEE, R_KNEE = 5, 6, 11, 12, 13, 14

# A few reference colours per name so light and dark blue both come out as
# "blue". We pick whichever swatch is closest in CIELAB.
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
    """BGR pixels (N x 3) to CIELAB."""
    px = bgr_pixels.reshape(-1, 1, 3).astype(np.float32) / 255
    return cv2.cvtColor(px, cv2.COLOR_BGR2LAB).reshape(-1, 3)


_CHROMATIC = np.array([n not in ("black", "grey", "white") for n in _NAMES])


def name_lab(lab):
    """Name a CIELAB colour.

    Greys/blacks/whites go by lightness alone. Lighting throws these around a
    lot (black in sunlight is often L 20-30, white in shade can be L 70-80 and
    a bit blue), hence the fairly loose cut-offs. Anything with real colour
    goes to the nearest swatch.
    """
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
    """Rough skin detector that works for any skin tone.

    Deliberately strict, because hi-vis vests and other bright orange/red
    clothing are close to skin and we really don't want those masked out.
    """
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
    """Pixels that match this particular person's skin colour.

    Skin between the face and the arms can look very different depending on
    light, but mostly in brightness and saturation, not hue. So we accept
    either a close colour or the same hue at a similar strength.
    """
    lab = lab_of(bgr_pixels)
    ab, ref_ab = lab[:, 1:], ref_lab[1:]
    chroma, ref_chroma = np.hypot(ab[:, 0], ab[:, 1]), float(np.hypot(*ref_ab))
    hue = np.degrees(np.arctan2(ab[:, 1], ab[:, 0]))
    ref_hue = float(np.degrees(np.arctan2(ref_ab[1], ref_ab[0])))
    hue_diff = np.abs((hue - ref_hue + 180) % 360 - 180)
    close = np.linalg.norm(ab - ref_ab, axis=1) < 10
    same_hue = ((hue_diff < 18) & (chroma > ref_chroma * 0.55)
                & (chroma < ref_chroma * 1.45))
    # skin always has some colour, so grey/black/white fabric can't match
    return (close | same_hue) & (chroma > 7) & (np.abs(lab[:, 0] - ref_lab[0]) < 35)


def plausible_skin(lab):
    """Sanity check on a skin sample. Shadows, cap brims, sunglasses or a
    strong colour cast can ruin it, and no reference beats a wrong one."""
    L, a, b = (float(v) for v in lab)
    chroma = float(np.hypot(a, b))
    hue = float(np.degrees(np.arctan2(b, a)))
    return 12 <= L <= 92 and 8 <= chroma <= 55 and 15 <= hue <= 85


def skin_reference(frame, face_box=None, kp=None, min_conf=0.5):
    """The person's own skin colour in CIELAB, or None.

    Tries the middle of the face first, then a bare forearm. face_box is
    (x, y, w, h).
    """
    if face_box is not None:
        # We already know this is a face, so the cheeks/nose area is skin no
        # matter the tone. That's better than the generic rule, which
        # struggles with darker skin. Drop the really dark bits (sunglasses,
        # nostrils) and glare.
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
            if len(px) >= 30 and skin.mean() >= 0.6:         # looks like a bare forearm
                ref = np.median(lab_of(px[skin]), axis=0)
                if plausible_skin(ref):
                    return ref
    return None


def skin_mask(bgr_pixels, skin_lab=None):
    """Skin pixels, using the person's own skin tone if we have it."""
    if skin_lab is None:
        return generic_skin(bgr_pixels)
    return matches(bgr_pixels, skin_lab)


def _quad_mask(shape, pts):
    m = np.zeros(shape[:2], np.uint8)
    cv2.fillConvexPoly(m, np.int32(pts), 1)
    return m.astype(bool)


def _shrink(pts, factor):
    """Pull a polygon in towards its centre so we stay clear of the edges,
    background and arms."""
    pts = np.float32(pts)
    c = pts.mean(axis=0)
    return c + (pts - c) * factor


def _band(a, b, start, end, width):
    """A strip `width` px wide along a->b, from `start` to `end` (fractions)."""
    a, b = np.float32(a), np.float32(b)
    d = b - a
    n = np.float32([-d[1], d[0]]) / (np.linalg.norm(d) + 1e-6) * width / 2
    p, q = a + d * start, a + d * end
    return [p + n, p - n, q - n, q + n]


def body_regions(kp, box=None, min_conf=0.5):
    """Torso and thigh polygons from COCO keypoints. Either can be None.

    Ideal case is both shoulders and both hips (front or back view). For
    side views and close-ups we make do with one side, or failing that just
    the upper arm (the sleeve tells us about the top). If the knees are out
    of shot (cut off, behind a car door...) we take the bit just below the
    hips that's still inside the person's box.
    """
    ok = lambda *ids: all(kp[i][2] >= min_conf for i in ids)
    pt = lambda i: np.float32(kp[i][:2])
    torso = thighs = None

    if ok(L_SHOULDER, R_SHOULDER, L_HIP, R_HIP):
        ls, rs, lh, rh = (pt(i) for i in (L_SHOULDER, R_SHOULDER, L_HIP, R_HIP))
        # from just below the collar to just above the belt
        torso = _shrink([ls + (lh - ls) * 0.12, rs + (rh - rs) * 0.12,
                         rs + (rh - rs) * 0.92, ls + (lh - ls) * 0.92], 0.75)
    else:
        for sho, hip, elbow in ((L_SHOULDER, L_HIP, 7), (R_SHOULDER, R_HIP, 8)):
            if ok(sho, hip):                       # side view
                length = float(np.linalg.norm(pt(hip) - pt(sho)))
                torso = _band(pt(sho), pt(hip), 0.15, 0.85, length * 0.3)
                break
            if ok(sho, elbow):                     # close-up, use the sleeve
                length = float(np.linalg.norm(pt(elbow) - pt(sho)))
                if length >= 15:
                    torso = _band(pt(sho), pt(elbow), 0.1, 0.4, length * 0.3)
                    break

    if ok(L_HIP, R_HIP, L_KNEE, R_KNEE):
        lh, rh, lk, rk = (pt(i) for i in (L_HIP, R_HIP, L_KNEE, R_KNEE))
        # top 2/3 of the thighs, so shorts still count as a bottom
        thighs = _shrink([lh + (lk - lh) * 0.08, rh + (rk - rh) * 0.08,
                          rh + (rk - rh) * 0.66, lh + (lk - lh) * 0.66], 0.8)
    else:
        for hip, knee in ((L_HIP, L_KNEE), (R_HIP, R_KNEE)):
            if ok(hip, knee):                      # side view
                length = float(np.linalg.norm(pt(knee) - pt(hip)))
                thighs = _band(pt(hip), pt(knee), 0.1, 0.66, length * 0.3)
                break
        if thighs is None and ok(L_SHOULDER, R_SHOULDER, L_HIP, R_HIP) and box is not None:
            ls, rs, lh, rh = (pt(i) for i in (L_SHOULDER, R_SHOULDER, L_HIP, R_HIP))
            down = np.float32([0.0, np.linalg.norm((lh + rh) / 2 - (ls + rs) / 2) * 0.45])
            hip_y = float(max(lh[1], rh[1]))
            bottom = min(float(box[3]), hip_y + float(down[1]))
            if bottom - hip_y > down[1] * 0.6:     # only if enough of it is in shot
                thighs = _shrink([lh + down * 0.15, rh + down * 0.15,
                                  np.float32([rh[0], bottom]), np.float32([lh[0], bottom])], 0.8)
    return torso, thighs


def describe_region(frame, polygon, skin_lab=None, min_pixels=150,
                    bare_share=0.6):
    """Name what's in the polygon: (colour, share), ("none", share) for bare
    skin, or (None, 0) if there isn't enough to go on. share is how much of
    the region that answer covers."""
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
    """Wrapper for the yolo26s-pose model."""

    def __init__(self, weights="yolo26s-pose.pt", device=None):
        from ultralytics import YOLO
        self.model = YOLO(weights)
        self.device = device

    def keypoints(self, frame, box, pad=0.1):
        """Keypoints (17 x [x, y, conf]) for the person in `box`, or None."""
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
        # the pose model may find several people in the crop, take the one matching our box
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
