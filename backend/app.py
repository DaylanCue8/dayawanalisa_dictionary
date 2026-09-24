import os
import uuid

import joblib
import mysql.connector
from flask import Flask, request, jsonify
from flask_cors import CORS

from baybayin_marker_service import preprocess_and_predict as preprocess_and_predict_marker
from baybayin_pen_service import (
    preprocess_and_predict as preprocess_and_predict_pen,
    BLURRY_IMAGE_MESSAGE,
)
from tagalog_to_baybayin import TagalogToBaybayin
from baybayin_disambiguation import load_filipino_word_set

app = Flask(__name__)
CORS(app)

ttb_translator = TagalogToBaybayin()

# --- 1. AI & ARCHIVE PATH CONFIG ---
ARCHIVE_ROOT = 'open_archival_dataset'
TEMP_ROOT = 'temp_crops'

for folder in [ARCHIVE_ROOT, TEMP_ROOT]:
    os.makedirs(folder, exist_ok=True)

# IMPORTANT: these .pkl files must come from a model trained on the
# CLEANED dataset (cropped + 12% margin + square-padded). The service
# modules now frame every crop that way via normalize_for_model, so
# older models trained on plain-resized images will not match.
try:
    base_model = joblib.load('model_base.pkl')
    dia_model = joblib.load('model_dia.pkl')
    model_metadata = joblib.load('model_metadata.pkl')
    base_classes = model_metadata['base_classes']
    dia_classes = model_metadata['dia_classes']
    print(f"✅ AI System Online. Loaded {len(base_classes)} base and {len(dia_classes)} diacritic classes.")
    print(f"   Base classes: {base_classes}")
    print(f"   Diacritic classes: {dia_classes}")
except Exception as e:
    print(f"❌ Critical Error: Could not load AI files. {e}")
    base_model, dia_model, base_classes, dia_classes = None, None, [], []

try:
    FILIPINO_WORD_SET = load_filipino_word_set('Tagalog_words_74419+.csv')
    print(f"✅ Filipino dictionary loaded: {len(FILIPINO_WORD_SET)} unique words.")
except Exception as e:
    print(f"❌ Could not load Filipino word list: {e}")
    FILIPINO_WORD_SET = set()

# --- 2. DATABASE CONFIG ---
db_config = {
    'host': 'localhost',
    'user': 'root',
    'password': '',
    'database': 'dayaw'
}

# --- 3. DATABASE HELPERS ---

def get_db_connection():
    return mysql.connector.connect(**db_config)


def start_processing_session(ip_address):
    conn = None
    cursor = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        query = "INSERT INTO processing_sessions (status, ip_address) VALUES ('Processing', %s)"
        cursor.execute(query, (ip_address,))
        new_id = cursor.lastrowid
        conn.commit()
        return new_id
    except Exception as e:
        print(f"❌ DB Session Error: {e}")
        return 0
    finally:
        if cursor is not None:
            cursor.close()
        if conn is not None and conn.is_connected():
            conn.close()


def log_detections(session_id, detections_list):
    if not detections_list or session_id == 0:
        return
    conn = None
    cursor = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        formatted_logs = [(session_id, d['char'], d['confidence']) for d in detections_list]
        query = "INSERT INTO detection_logs (session_id, detected_char, confidence_score) VALUES (%s, %s, %s)"
        cursor.executemany(query, formatted_logs)
        conn.commit()
    except Exception as e:
        print(f"❌ Log Error: {e}")
    finally:
        if cursor is not None:
            cursor.close()
        if conn is not None and conn.is_connected():
            conn.close()


def update_session_status(session_id, status):
    if session_id == 0:
        return
    conn = None
    cursor = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        query = "UPDATE processing_sessions SET status = %s, end_time = CURRENT_TIMESTAMP WHERE session_id = %s"
        cursor.execute(query, (status, session_id))
        conn.commit()
    except Exception as e:
        print(f"❌ Update Error: {e}")
    finally:
        if cursor is not None:
            cursor.close()
        if conn is not None and conn.is_connected():
            conn.close()


# --- 4. REQUEST HELPERS ---

def get_request_value(name):
    """
    Reads a field from multipart form data first, then from a JSON body.
    Returns None if it's in neither - never crashes when the request has
    no JSON body (request.json would be None in that case).
    """
    if name in request.form:
        return request.form.get(name)
    json_body = request.get_json(silent=True) or {}
    return json_body.get(name)


def is_inside_temp_root(path):
    """
    temp_path comes back from the client, so it must be verified to
    point inside TEMP_ROOT before it is ever renamed or moved.
    """
    temp_root = os.path.realpath(TEMP_ROOT)
    real_path = os.path.realpath(path)
    return real_path.startswith(temp_root + os.sep)


# --- 5. PIPELINE SELECTION ---

# The Baybayin OCR pipeline lives in two fully independent modules:
#   - baybayin_marker_service.py  (marker / pentel_pen)
#   - baybayin_pen_service.py     (ballpoint / gel pen)
# They share no code and no constants, so calibrating one cannot affect
# the other. 'pentel_pen' is an alias for 'marker'; anything unrecognized
# also falls back to 'marker' so a bad value never crashes the request.
VALID_INPUT_TYPES = {'marker', 'pentel_pen', 'pen'}


def get_predict_function(input_type):
    if input_type == 'pen':
        return preprocess_and_predict_pen
    return preprocess_and_predict_marker


# --- 6. API ROUTES ---

@app.route('/api/translate', methods=['POST'])
def translate():
    session_id = start_processing_session(request.remote_addr)
    mode = get_request_value('mode')

    raw_input_type = get_request_value('input_type')
    input_type = raw_input_type if raw_input_type in VALID_INPUT_TYPES else 'marker'

    try:
        if mode == 'Baybayin to Tagalog':
            if 'file' not in request.files:
                update_session_status(session_id, 'No_File')
                return jsonify({"error": "No image uploaded"}), 400

            image_bytes = request.files['file'].read()

            predict_fn = get_predict_function(input_type)
            text, conf, results, image_dims = predict_fn(
                image_bytes, session_id, base_model, dia_model, base_classes, dia_classes,
                filipino_word_set=FILIPINO_WORD_SET,
            )

            log_detections(session_id, results)

            # Blur rejection is checked FIRST and separately - a blurry
            # photo must never be reported as "No_Characters", since the
            # user fixes those differently (hold steadier vs. write more
            # clearly). Both the pen and marker pipelines perform this
            # check and return the identical message string.
            if text == BLURRY_IMAGE_MESSAGE:
                status = "Blurry_Image"
            elif not results:
                status = "No_Characters"
            elif conf > 60:
                status = "Success"
            else:
                status = "Low_Confidence"
            update_session_status(session_id, status)

            return jsonify({
                "translated_text": text,
                "confidence": conf,
                "status": status,
                "individual_detections": results,
                "image_width": image_dims['width'],
                "image_height": image_dims['height'],
                "session_id": session_id,
                "input_type_used": input_type
            })

        elif mode == 'Tagalog to Baybayin':
            input_text = get_request_value('text')
            if not input_text:
                update_session_status(session_id, 'No_Text')
                return jsonify({"error": "No text provided"}), 400

            translated_result, confidence = ttb_translator.translate(input_text)
            update_session_status(session_id, "Success")

            return jsonify({
                "translated_text": translated_result,
                "confidence": confidence,
                "session_id": session_id
            })

        else:
            update_session_status(session_id, 'Invalid_Mode')
            return jsonify({
                "error": "Invalid or missing mode. Use 'Baybayin to Tagalog' or 'Tagalog to Baybayin'."
            }), 400

    except Exception as e:
        import traceback
        print("❌ /api/translate crashed with an exception:")
        traceback.print_exc()
        update_session_status(session_id, 'Error')
        return jsonify({"error": str(e)}), 500


@app.route('/api/archive_bulk', methods=['POST'])
def archive_bulk():
    data = request.get_json(silent=True) or {}
    session_id = data.get('session_id')
    detections = data.get('detections', [])

    if not detections:
        return jsonify({"status": "Ignored", "message": "No detections to archive"}), 200

    conn = None
    cursor = None
    try:
        conn = get_db_connection()
        cursor = conn.cursor()
        saved_count = 0
        archive_data = []

        for d in detections:
            char = d.get('char')
            confidence = d.get('confidence')
            temp_path = d.get('temp_path')
            is_eligible = d.get('is_eligible', False)

            if not char or not temp_path or not os.path.exists(temp_path) or not is_eligible:
                continue

            # temp_path is client-supplied: only ever touch files that
            # really live inside TEMP_ROOT.
            if not is_inside_temp_root(temp_path):
                continue

            # A char still containing '{' or '/' is an unresolved
            # ambiguity slot (e.g. '{d/r}a'). Archiving it would create
            # nested garbage folders (the '/' is a path separator) and
            # record a guess as a confirmed label, so it's skipped.
            if '{' in char or '/' in char:
                continue

            char_dir = os.path.join(ARCHIVE_ROOT, char)
            os.makedirs(char_dir, exist_ok=True)

            # Keep the crop's prediction-based name from the services
            # (e.g. 'A_136_6103f3.png' = predicted class, crop index,
            # random id). The folder is the confirmed label, the file
            # name is what the model predicted, so a mismatch between
            # the two shows where the model needed correcting. PNG
            # (lossless), already in the 56x56 training format.
            final_filename = os.path.basename(temp_path)
            final_path = os.path.join(char_dir, final_filename)
            if os.path.exists(final_path):
                stem, ext = os.path.splitext(final_filename)
                final_path = os.path.join(
                    char_dir, f"{stem}_s{session_id}_{uuid.uuid4().hex[:4]}{ext}"
                )

            os.rename(temp_path, final_path)
            archive_data.append((session_id, char, confidence, True))
            saved_count += 1

        if archive_data:
            query = """
                INSERT INTO open_archival
                (session_id, char_label, confidence_score, verified_by_user)
                VALUES (%s, %s, %s, %s)
            """
            cursor.executemany(query, archive_data)
            conn.commit()

        # Cleanup
        session_temp_dir = os.path.join(TEMP_ROOT, f"session_{session_id}")
        if os.path.exists(session_temp_dir):
            for file in os.listdir(session_temp_dir):
                os.remove(os.path.join(session_temp_dir, file))
            os.rmdir(session_temp_dir)

        return jsonify({"status": "Success", "message": f"Archived {saved_count} entries"}), 200

    except Exception as e:
        return jsonify({"error": str(e)}), 500
    finally:
        if cursor is not None:
            cursor.close()
        if conn is not None and conn.is_connected():
            conn.close()


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)