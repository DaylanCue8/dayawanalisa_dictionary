"""
Shared setup for the Python test tools: makes the app's on-phone
recognizer code (android/app/src/main/python) importable, and gives the
exact feature extraction + class names the app uses, so every number
these tools report describes the real app - not a re-implementation.
"""
import json
import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
# Where the command was run from - captured before baybayin_offline
# chdir()s to $HOME, so relative paths on the command line still work.
START_DIR = os.getcwd()


def user_path(path):
    """A command-line path, resolved against the folder the tool was run from."""
    return path if os.path.isabs(path) else os.path.join(START_DIR, path)
APP_PYTHON = os.path.normpath(os.path.join(HERE, '..', 'android', 'app', 'src', 'main', 'python'))
MODEL_DIR = os.path.join(APP_PYTHON, 'models')

# baybayin_offline.py works from $HOME (the app's storage on Android).
# Point it at a throw-away folder so tests never litter the repo.
os.environ.setdefault('HOME', tempfile.mkdtemp(prefix='dayaw_test_home_'))
if APP_PYTHON not in sys.path:
    sys.path.insert(0, APP_PYTHON)
# baybayin_offline chdir()s to $HOME on import, so relative imports of
# these tools would break - keep this folder on the path by absolute path.
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import numpy as np  # noqa: E402
import cv2  # noqa: E402

from offline_svm import OfflineSVC  # noqa: E402
from baybayin_hog import hog  # noqa: E402
import baybayin_marker_service as marker  # noqa: E402

with open(os.path.join(MODEL_DIR, 'classes.json'), encoding='utf-8') as f:
    CLASSES = json.load(f)

# The same HOG settings classify_glyph() uses for each model.
HOG_PARAMS = {
    'base': dict(orientations=9, pixels_per_cell=(8, 8), cells_per_block=(2, 2),
                 transform_sqrt=True, visualize=False),
    'dia': dict(orientations=9, pixels_per_cell=(4, 4), cells_per_block=(1, 1),
                transform_sqrt=True, visualize=False),
}


def load_model(kind):
    """The on-phone SVM ('base' or 'dia') and its class names."""
    model = OfflineSVC(os.path.join(MODEL_DIR, f'model_{kind}.npz'))
    return model, CLASSES[f'{kind}_classes']


def image_to_ink_mask(gray):
    """Grayscale image -> uint8 mask, ink = 255. Works for dark-on-light
    photos and for light-on-dark (already cleaned) glyphs alike."""
    _, binary = cv2.threshold(gray, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
    # ink is the minority colour
    if np.count_nonzero(binary) > binary.size / 2:
        binary = 255 - binary
    return binary


def features(mask, kind):
    """The exact model input the app builds: frame like the training set
    (normalize_for_model), scale to 0..1, HOG with the model's settings."""
    model_input = marker._to_model_float(mask)
    return hog(model_input, **HOG_PARAMS[kind]).reshape(1, -1)
