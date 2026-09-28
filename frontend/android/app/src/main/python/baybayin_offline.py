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
    Tagalog_words_74419+.csv
    tagalog_to_baybayin.py   (optional - only for the text mode)
"""
import json
import os
import shutil
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
MODEL_DIR = os.path.join(HERE, 'models')
WORD_LIST_PATH = os.path.join(HERE, 'Tagalog_words_74419+.csv')

# The services save each glyph crop under ./temp_crops. On Android the
# only writable place is the app's own storage, which Chaquopy puts in
# HOME - so work from there.
os.chdir(os.environ.get('HOME', HERE))

_lock = threading.Lock()
_state = {}


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
    with _lock:
        _load()
    return 'ok'


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
            text, conf, results, image_dims = service.preprocess_and_predict(
                bytes(image_bytes), session_id,
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
        })
    except Exception as e:
        traceback.print_exc()
        return _to_json({'error': str(e), 'status': 'Error'})
    finally:
        # no archive offline: don't let saved crops fill up the phone
        shutil.rmtree(os.path.join('temp_crops', f'session_{session_id}'), ignore_errors=True)


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
