"""
vehicle_classifier.py - recognises a vehicle's MAKE (brand) and COLOUR from
a cropped picture of the vehicle.

Uses two small pretrained models by Spectrico (MobileNet v3, MIT licence),
taken from https://github.com/TheDeveloperMask/vehicle-recognition-api-yolov4-python
(see vehicle_models/LICENSE). We only use their two classifiers; vehicles
are found and tracked by our own YOLO + tracker in detector.py.

Each model returns a PROBABILITY for every possible answer (all 397 makes,
all 14 colours), adding up to 1. detector.py adds these up over many frames
("soft voting"), which is more reliable than only counting each frame's
top answer.

Accuracy helpers (all automatic):
  * mirror check - a car looks the same flipped left-right, so the make is
    judged on the picture AND its mirror image and the two are averaged.
    This smooths out one-off mistakes.
  * low-light boost - dark (night / dawn) pictures get a contrast boost
    (CLAHE) before the make is judged. Not used for colour, because
    brightening a picture changes how its colour looks.
  * sharpness - a score for how blurry a picture is, used by detector.py to
    give blurry frames less say (or none).

Changes from Spectrico's original classifier.py: the picture is passed to
MNN as 32-bit floats (newer MNN/numpy versions crash on the 64-bit floats
the original used), and all probabilities are returned, not only the top one.
"""

from pathlib import Path

import cv2
import MNN
import numpy as np

MODELS = Path(__file__).parent / "vehicle_models"


def _load_labels(path):
    with open(path, "r", encoding="utf-8") as f:
        return [line.strip() for line in f if line.strip()]


def sharpness(bgr_crop):
    """How sharp a picture is (higher = sharper).

    The "variance of the Laplacian": the Laplacian highlights edges, and a
    blurry picture has few strong edges, so the number is low. The picture
    is resized first so big and small crops are scored on the same scale.
    Rough guide: under ~15 very blurry, 50-150 okay, over 150 sharp.
    """
    grey = cv2.cvtColor(bgr_crop, cv2.COLOR_BGR2GRAY)
    grey = cv2.resize(grey, (224, 224))
    return float(cv2.Laplacian(grey, cv2.CV_64F).var())


def brightness(bgr_crop):
    """Average brightness 0 (black) - 255 (white)."""
    return float(cv2.cvtColor(bgr_crop, cv2.COLOR_BGR2GRAY).mean())


def boost_low_light(bgr_crop):
    """Brings out detail in a dark picture (CLAHE contrast boost).

    Works on the brightness channel only (LAB colour space), so shapes and
    edges - what the make model looks at - become clearer.
    """
    lab = cv2.cvtColor(bgr_crop, cv2.COLOR_BGR2LAB)
    l, a, b = cv2.split(lab)
    l = cv2.createCLAHE(clipLimit=2.5, tileGridSize=(8, 8)).apply(l)
    return cv2.cvtColor(cv2.merge((l, a, b)), cv2.COLOR_LAB2BGR)


class _Classifier:
    """Runs one Spectrico .mnn model on a 224x224 picture."""

    def __init__(self, model_file, labels_file):
        self.interpreter = MNN.Interpreter(str(model_file))
        self.session = self.interpreter.createSession()
        self.input_tensor = self.interpreter.getSessionInput(self.session)
        self.labels = _load_labels(labels_file)

    def probabilities(self, bgr_crop):
        """Probability of every label (numpy array adding up to 1)."""
        image = cv2.resize(bgr_crop, (224, 224))[..., ::-1]   # BGR -> RGB
        image = image.astype(np.float32)
        image = (image - 127.5) * 0.00784                       # scale to -1..1
        image = np.ascontiguousarray(image.transpose((2, 0, 1)))  # HWC -> CHW

        tensor = MNN.Tensor((1, 3, 224, 224), MNN.Halide_Type_Float,
                            image, MNN.Tensor_DimensionType_Caffe)
        self.input_tensor.copyFrom(tensor)
        self.interpreter.runSession(self.session)
        return np.array(self.interpreter.getSessionOutput(self.session).getData(),
                        dtype=np.float32).flatten()

    def predict(self, bgr_crop):
        """(best label, its probability 0-1)."""
        probs = self.probabilities(bgr_crop)
        best = int(probs.argmax())
        return self.labels[best], float(probs[best])


class VehicleClassifier:
    """Make + colour of a cropped vehicle picture."""

    # Pictures darker than this (0-255) get the low-light boost for make.
    DARK = 80

    def __init__(self, models_dir=MODELS):
        models_dir = Path(models_dir)
        self.make_model = _Classifier(
            models_dir / "model-weights-spectrico-car-brand-recognition-mobilenet_v3-224x224-170620.mnn",
            models_dir / "labels-makes.txt")
        self.colour_model = _Classifier(
            models_dir / "model-weights-spectrico-car-colors-recognition-mobilenet_v3-224x224-180420.mnn",
            models_dir / "labels-colors.txt")

    @property
    def make_labels(self):
        return self.make_model.labels

    @property
    def colour_labels(self):
        return self.colour_model.labels

    def make_probabilities(self, bgr_crop):
        """Probability of every make, with the low-light boost (if dark)
        and the mirror check (picture + its mirror image, averaged)."""
        if brightness(bgr_crop) < self.DARK:
            bgr_crop = boost_low_light(bgr_crop)
        normal = self.make_model.probabilities(bgr_crop)
        mirrored = self.make_model.probabilities(cv2.flip(bgr_crop, 1))
        return (normal + mirrored) / 2

    def colour_probabilities(self, bgr_crop):
        """Probability of every colour (original picture, no boost)."""
        return self.colour_model.probabilities(bgr_crop)

    def make(self, bgr_crop):
        """e.g. ("Toyota", 0.93) - one picture, with the accuracy helpers."""
        probs = self.make_probabilities(bgr_crop)
        best = int(probs.argmax())
        return self.make_labels[best], float(probs[best])

    def colour(self, bgr_crop):
        """e.g. ("white", 0.88). Colours: black white grey silver blue red
        green brown beige golden bordeaux yellow violet orange"""
        return self.colour_model.predict(bgr_crop)
