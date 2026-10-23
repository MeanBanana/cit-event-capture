"""
Make and colour classifiers for a cropped vehicle.

These are Spectrico's two MobileNet v3 models (MIT licence), pulled from
https://github.com/TheDeveloperMask/vehicle-recognition-api-yolov4-python
(see vehicle_models/LICENSE). We only use the classifiers, finding and
tracking vehicles is our own YOLO + tracker in detector.py.

Both models return a full probability distribution (397 makes, 14 colours)
and detector.py sums those over frames. That works a lot better than just
counting each frame's top answer.

A few tricks to squeeze out more accuracy:
  - we run make on the crop and its mirror image and average them. Cars are
    roughly symmetric so this smooths out one-off mistakes.
  - dark crops get a CLAHE contrast boost before the make model sees them.
    Not for colour though, boosting changes the colour.
  - sharpness() lets detector.py down-weight or skip blurry frames.

Two changes from Spectrico's original code: we pass float32 to MNN (newer
MNN/numpy crash on float64), and we return all probabilities instead of only
the top one.
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
    """Laplacian variance, i.e. how sharp the crop is.

    Blurry images have weak edges so the number comes out low. We resize
    first so big and small crops are comparable. Ballpark: below 15 is very
    blurry, 50-150 is fine, 150+ is sharp.
    """
    grey = cv2.cvtColor(bgr_crop, cv2.COLOR_BGR2GRAY)
    grey = cv2.resize(grey, (224, 224))
    return float(cv2.Laplacian(grey, cv2.CV_64F).var())


def brightness(bgr_crop):
    """Mean brightness, 0-255."""
    return float(cv2.cvtColor(bgr_crop, cv2.COLOR_BGR2GRAY).mean())


def boost_low_light(bgr_crop):
    """CLAHE on the L channel only, to pull detail out of dark images
    without messing with the colours."""
    lab = cv2.cvtColor(bgr_crop, cv2.COLOR_BGR2LAB)
    l, a, b = cv2.split(lab)
    l = cv2.createCLAHE(clipLimit=2.5, tileGridSize=(8, 8)).apply(l)
    return cv2.cvtColor(cv2.merge((l, a, b)), cv2.COLOR_LAB2BGR)


class _Classifier:
    """One Spectrico .mnn model."""

    def __init__(self, model_file, labels_file):
        self.interpreter = MNN.Interpreter(str(model_file))
        self.session = self.interpreter.createSession()
        self.input_tensor = self.interpreter.getSessionInput(self.session)
        self.labels = _load_labels(labels_file)

    def probabilities(self, bgr_crop):
        """Probabilities for every label."""
        image = cv2.resize(bgr_crop, (224, 224))[..., ::-1]   # model wants RGB
        image = image.astype(np.float32)
        image = (image - 127.5) * 0.00784                       # roughly -1..1
        image = np.ascontiguousarray(image.transpose((2, 0, 1)))  # HWC -> CHW

        tensor = MNN.Tensor((1, 3, 224, 224), MNN.Halide_Type_Float,
                            image, MNN.Tensor_DimensionType_Caffe)
        self.input_tensor.copyFrom(tensor)
        self.interpreter.runSession(self.session)
        return np.array(self.interpreter.getSessionOutput(self.session).getData(),
                        dtype=np.float32).flatten()

    def predict(self, bgr_crop):
        """Top label and its probability."""
        probs = self.probabilities(bgr_crop)
        best = int(probs.argmax())
        return self.labels[best], float(probs[best])


class VehicleClassifier:
    """Make + colour for a vehicle crop."""

    # below this mean brightness we apply the low-light boost (make only)
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
        """Make probabilities, with the low-light boost and mirror averaging."""
        if brightness(bgr_crop) < self.DARK:
            bgr_crop = boost_low_light(bgr_crop)
        normal = self.make_model.probabilities(bgr_crop)
        mirrored = self.make_model.probabilities(cv2.flip(bgr_crop, 1))
        return (normal + mirrored) / 2

    def colour_probabilities(self, bgr_crop):
        """Colour probabilities. No boost here on purpose."""
        return self.colour_model.probabilities(bgr_crop)

    def make(self, bgr_crop):
        """Single-image make, e.g. ("Toyota", 0.93)."""
        probs = self.make_probabilities(bgr_crop)
        best = int(probs.argmax())
        return self.make_labels[best], float(probs[best])

    def colour(self, bgr_crop):
        """Single-image colour, e.g. ("white", 0.88)."""
        return self.colour_model.predict(bgr_crop)
