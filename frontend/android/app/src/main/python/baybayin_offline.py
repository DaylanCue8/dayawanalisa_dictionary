"""
Offline entry point for the Android app (runs inside Chaquopy).

Does what app.py's /api/translate did, but on the phone and without Flask,
MySQL or scikit-learn:
    recognize(image_bytes, input_type) -> JSON string, same fields as the
                                          Flask response
    translate_text(text)               -> JSON string for Tagalog -> Baybayin
    warm_up()                          -> loads the models ahead of time

Files that must sit next to this one (android/app/src/main/python/):
    baybayin_pen_service.py, baybayin_marker_service.py,
    baybayin_disambiguation.py, baybayin_hog.py, offline_svm.py,
    models/model_base.npz, models/model_dia.npz, models/classes.json,
    Tagalog_words.csv
    tagalog_to_baybayin.py   (optional - only for the text mode)
"""
import gc
import json
import os
import shutil
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR = os.path.join(HERE, 'models')
WORD_LIST_PATH = os.path.join(HERE, 'Tagalog_words.csv')

# The services save each glyph crop under ./temp_crops. On Android the
# only writable place is the app's own storage, which Chaquopy puts in
# HOME - so work from there.
os.chdir(os.environ.get('HOME', HERE))

_lock = threading.Lock()
_state = {}

# ---- CRASH RECORDER ----
# A crash inside compiled code (OpenCV/NumPy) kills the app before Python
# can report anything. faulthandler writes the Python line that was running
# to crash_trace.txt at that moment; the next scan sends it back to Flutter
# (field 'previous_crash', printed in the `flutter run` console).
import faulthandler
_CRASH_FILE = os.path.join(os.environ.get('HOME', HERE), 'crash_trace.txt')
_previous_crash = None
try:
    if os.path.exists(_CRASH_FILE) and os.path.getsize(_CRASH_FILE) > 0:
        with open(_CRASH_FILE, encoding='utf-8', errors='replace') as _f:
            _previous_crash = _f.read()[-4000:]
        print('[offline] PREVIOUS CRASH:\n' + _previous_crash)
    _crash_fh = open(_CRASH_FILE, 'w')
    faulthandler.enable(file=_crash_fh, all_threads=True)
except Exception as _e:  # never let the recorder itself break the app
    print(f'[offline] crash recorder not available: {_e}')

# Big photos use a lot of memory on the phone (the pen pipeline makes
# several full-size copies: denoise, contrast, deskew). Photos larger than
# this on their longest side are shrunk first. 2400 px still leaves the
# letters big enough (a page of 5 lines x 20 letters -> letters ~150 px).
MAX_IMAGE_SIDE = 2400


def _limit_image_size(image_bytes):
    """Shrinks very large photos; returns (bytes, scale). Flutter already
    fixed the EXIF rotation, so re-encoding (PNG, lossless) is safe."""
    import numpy as np
    from baybayin_pen_service import cv2   # the crash-guarded OpenCV
    data = np.frombuffer(image_bytes, dtype=np.uint8)
    img = cv2.imdecode(data, cv2.IMREAD_COLOR)
    if img is None:
        return image_bytes, 1.0
    h, w = img.shape[:2]
    if max(h, w) <= MAX_IMAGE_SIDE:
        return image_bytes, 1.0
    scale = MAX_IMAGE_SIDE / float(max(h, w))
    small = cv2.resize(img, (int(round(w * scale)), int(round(h * scale))),
                       interpolation=cv2.INTER_AREA)
    ok, buf = cv2.imencode('.png', small)
    del img, small, data
    return (buf.tobytes(), scale) if ok else (image_bytes, 1.0)


def _load():
    """Loads the models, class names and word list once."""
    if _state:
        return _state
    from offline_svm import OfflineSVC
    from baybayin_disambiguation import load_filipino_word_set
    import baybayin_pen_service
    import baybayin_marker_service

    with open(os.path.join(MODEL_DIR, 'classes.json'), encoding='utf-8') as f:
        classes = json.load(f)
    _state['base_model'] = OfflineSVC(os.path.join(MODEL_DIR, 'model_base.npz'))
    _state['dia_model'] = OfflineSVC(os.path.join(MODEL_DIR, 'model_dia.npz'))
    _state['base_classes'] = classes['base_classes']
    _state['dia_classes'] = classes['dia_classes']
    try:
        _state['word_set'] = load_filipino_word_set(WORD_LIST_PATH)
    except Exception as e:  # recognition still works, only the e/i-o/u fix is skipped
        print(f'[offline] Could not load Filipino word list: {e}')
        _state['word_set'] = set()
    _state['pen'] = baybayin_pen_service
    _state['marker'] = baybayin_marker_service
    return _state


def warm_up():
    """Loads the models. Returns JSON; 'previous_crash' holds the Python
    stack recorded by faulthandler if the app crashed last time (else null),
    so the app can show it on screen."""
    with _lock:
        _load()
    return json.dumps({'ok': True, 'previous_crash': _previous_crash})


def _to_json(payload):
    def default(value):
        try:
            return value.item()          # numpy numbers
        except AttributeError:
            return str(value)
    return json.dumps(payload, default=default, ensure_ascii=False)


def recognize(image_bytes, input_type='marker', debug=False):
    """
    image_bytes: the (cropped) JPEG/PNG bytes from Flutter.
    input_type : 'pen', 'marker' or 'pentel_pen' (anything else -> marker).
    Returns a JSON string with the same fields as the Flask API response.
    """
    session_id = int(time.time() * 1000) % 1_000_000_000
    input_type = input_type if input_type in ('pen', 'marker', 'pentel_pen') else 'marker'
    try:
        with _lock:
            state = _load()
            service = state['pen'] if input_type == 'pen' else state['marker']
            image_bytes, scale = _limit_image_size(bytes(image_bytes))
            if debug and scale != 1.0:
                print(f'[offline] photo shrunk to {scale:.2f}x to save memory')
            text, conf, results, image_dims = service.preprocess_and_predict(
                image_bytes, session_id,
                state['base_model'], state['dia_model'],
                state['base_classes'], state['dia_classes'],
                filipino_word_set=state['word_set'], debug=debug,
            )

        if text == service.BLURRY_IMAGE_MESSAGE:
            status = 'Blurry_Image'
        elif not results:
            status = 'No_Characters'
        elif conf > 60:
            status = 'Success'
        else:
            status = 'Low_Confidence'

        for item in results:
            item.pop('temp_path', None)   # the crop file is deleted below

        return _to_json({
            'translated_text': text,
            'confidence': conf,
            'status': status,
            'individual_detections': results,
            'image_width': image_dims['width'],
            'image_height': image_dims['height'],
            'session_id': session_id,
            'input_type_used': input_type,
            'offline': True,
            'previous_crash': _previous_crash,
        })
    except Exception as e:
        traceback.print_exc()
        return _to_json({'error': str(e), 'status': 'Error'})
    finally:
        # no archive offline: don't let saved crops fill up the phone
        shutil.rmtree(os.path.join('temp_crops', f'session_{session_id}'), ignore_errors=True)
        gc.collect()   # give the big temporary images back right away


def translate_text(text):
    """Tagalog -> Baybayin text mode (needs tagalog_to_baybayin.py)."""
    try:
        if 'ttb' not in _state:
            from tagalog_to_baybayin import TagalogToBaybayin
            _state['ttb'] = TagalogToBaybayin()
        translated, confidence = _state['ttb'].translate(text)
        return _to_json({'translated_text': translated, 'confidence': confidence,
                         'status': 'Success', 'offline': True})
    except Exception as e:
        traceback.print_exc()
        return _to_json({'error': str(e), 'status': 'Error'})