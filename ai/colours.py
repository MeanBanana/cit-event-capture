"""
Turns a patch of image into a colour word using k-means + HSV.

Only the vehicle fallback uses this now (when the Spectrico colour model
isn't available). Clothing has its own CIELAB-based naming in clothing.py.

We cluster the pixels into 3 groups (paint / windows / reflections, roughly)
and name the biggest one. OpenCV's HSV ranges are H 0-179, S and V 0-255.
"""

import cv2
import numpy as np


def colour_name(bgr):
    """Name a single BGR colour."""
    pixel = np.uint8([[bgr]])
    h, s, v = cv2.cvtColor(pixel, cv2.COLOR_BGR2HSV)[0][0]
    h, s, v = int(h), int(s), int(v)

    # really dark is black no matter the hue
    if v < 50:
        return "black"
    # barely any saturation means white/silver/grey, so go by brightness
    if s < 45:
        if v > 180:
            return "white"
        if v > 120:
            return "silver"
        return "grey"
    # otherwise it's an actual colour, go by hue
    if h < 8 or h >= 170:
        return "red"
    if h < 22:
        return "brown" if v < 140 else "orange"   # dark orange reads as brown
    if h < 35:
        return "yellow"
    if h < 85:
        return "green"
    if h < 130:
        return "blue"
    return "purple"


def dominant_colour(bgr_patch, min_pixels=50):
    """Main colour of the patch, or None if it's too small to say."""
    if bgr_patch is None or bgr_patch.size == 0:
        return None
    pixels = bgr_patch.reshape(-1, 3).astype(np.float32)
    if len(pixels) < min_pixels:
        return None
    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 10, 1.0)
    _, labels, centres = cv2.kmeans(
        pixels, 3, None, criteria, 3, cv2.KMEANS_PP_CENTERS)
    biggest_group = np.bincount(labels.flatten()).argmax()
    return colour_name(centres[biggest_group])
