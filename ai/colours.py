"""
colours.py - turns a patch of a picture into a colour word ("red", "black").

Shared by vehicles (fallback when the Spectrico colour model isn't loaded)
and by people (clothing colours).

How: k-means sorts the patch's pixels into 3 groups of similar colour
(e.g. paint / windows / reflections, or shirt / shadow / background) and we
name the biggest group. Naming uses HSV, which describes a colour the way
people do:
  H (hue)        which colour of the rainbow   (OpenCV: 0-179)
  S (saturation) how strong the colour is       (0 = grey, 255 = vivid)
  V (value)      how bright it is               (0 = black, 255 = bright)
"""

import cv2
import numpy as np


def colour_name(bgr):
    """One colour (Blue, Green, Red values 0-255) -> a word."""
    pixel = np.uint8([[bgr]])                      # a 1x1 "image" holding the colour
    h, s, v = cv2.cvtColor(pixel, cv2.COLOR_BGR2HSV)[0][0]
    h, s, v = int(h), int(s), int(v)

    # Very dark is black, whatever the hue.
    if v < 50:
        return "black"
    # Hardly any colour: white / silver / grey, decided by brightness.
    if s < 45:
        if v > 180:
            return "white"
        if v > 120:
            return "silver"
        return "grey"
    # A real colour: decided by hue.
    if h < 8 or h >= 170:
        return "red"
    if h < 22:
        return "brown" if v < 140 else "orange"   # dark orange looks brown
    if h < 35:
        return "yellow"
    if h < 85:
        return "green"
    if h < 130:
        return "blue"
    return "purple"


def dominant_colour(bgr_patch, min_pixels=50):
    """The main colour of a picture patch as a word, or None if the patch
    is too small to judge."""
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
