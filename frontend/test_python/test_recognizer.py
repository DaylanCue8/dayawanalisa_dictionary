"""
White-box tests for the on-phone recognizer (Python side). Standard
library unittest - no pytest needed:

    python -m unittest -v test_recognizer

Covers ERROR HANDLING (every bad input still returns valid JSON with a
clear status, never an exception across the Flutter bridge) and the
CONSISTENCY of the classifier plumbing (probabilities, labels, HOG
sizes) that CLASSIFICATION ACCURACY numbers depend on.
"""
import io
import json
import unittest

import _app
from _app import np, cv2
import baybayin_offline
from PIL import Image, ImageDraw, ImageFont

from make_synthetic_glyphs import FONT, GLYPHS

EXPECTED_KEYS = {'translated_text', 'confidence', 'status', 'individual_detections',
                 'image_width', 'image_height'}


def png_bytes(image):
    ok, buffer = cv2.imencode('.png', image)
    assert ok
    return buffer.tobytes()


def rendered_word(chars, size=900):
    """A crisp photo-like image of Baybayin text, dark ink on white."""
    font = ImageFont.truetype(FONT, 180)
    canvas = Image.new('L', (size, 400), 255)
    ImageDraw.Draw(canvas).text((size // 2, 200), chars, font=font, fill=0, anchor='mm')
    out = io.BytesIO()
    canvas.save(out, format='PNG')
    return out.getvalue()


def recognize(data, input_type='marker'):
    reply = baybayin_offline.recognize(data, input_type)
    return json.loads(reply)          # must ALWAYS be valid JSON


class ErrorHandlingTest(unittest.TestCase):
    def test_empty_bytes_is_invalid_image(self):
        reply = recognize(b'')
        self.assertEqual(reply['status'], 'Invalid_Image')
        self.assertNotIn('error', reply)
        self.assertTrue(EXPECTED_KEYS <= set(reply))

    def test_none_is_invalid_image(self):
        self.assertEqual(recognize(None)['status'], 'Invalid_Image')

    def test_garbage_bytes_is_invalid_image(self):
        reply = recognize(b'this is not an image at all' * 10)
        self.assertEqual(reply['status'], 'Invalid_Image')
        self.assertEqual(reply['translated_text'], '')
        self.assertEqual(reply['individual_detections'], [])

    def test_truncated_png_is_invalid_image(self):
        data = png_bytes(np.full((200, 200), 255, np.uint8))
        self.assertEqual(recognize(data[:40])['status'], 'Invalid_Image')

    def test_blank_page_has_no_characters(self):
        reply = recognize(png_bytes(np.full((600, 800), 255, np.uint8)))
        self.assertIn(reply['status'], ('No_Characters', 'Blurry_Image'))
        self.assertEqual(reply['individual_detections'], [])

    def test_blurry_photo_is_reported_as_blurry(self):
        sharp = cv2.imdecode(np.frombuffer(rendered_word('ᜊᜌ'), np.uint8), cv2.IMREAD_GRAYSCALE)
        blurry = cv2.GaussianBlur(sharp, (0, 0), 25)
        self.assertEqual(recognize(png_bytes(blurry))['status'], 'Blurry_Image')

    def test_unknown_input_type_falls_back_to_marker(self):
        reply = recognize(rendered_word('ᜊ'), input_type='crayon')
        self.assertEqual(reply['input_type_used'], 'marker')

    def test_temp_crops_are_cleaned_up(self):
        import os
        reply = recognize(rendered_word('ᜊᜌ'))
        folder = os.path.join('temp_crops', f'session_{reply["session_id"]}')
        self.assertFalse(os.path.exists(folder))


class RecognitionConsistencyTest(unittest.TestCase):
    def test_clear_word_is_read_with_valid_detections(self):
        reply = recognize(rendered_word('ᜊᜌ'))          # "baya"
        self.assertIn(reply['status'], ('Success', 'Low_Confidence'))
        self.assertGreater(reply['image_width'], 0)
        self.assertGreater(reply['image_height'], 0)
        self.assertEqual(len(reply['individual_detections']), 2)
        for d in reply['individual_detections']:
            box = d['bbox']
            self.assertLess(box['x0'], box['x1'])
            self.assertLess(box['y0'], box['y1'])
            self.assertGreaterEqual(d['confidence'], 0)

    def test_same_image_gives_same_result(self):
        data = rendered_word('ᜋᜎ')
        first, second = recognize(data), recognize(data)
        for key in ('translated_text', 'confidence', 'status'):
            self.assertEqual(first[key], second[key])


class ClassifierPlumbingTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.base, cls.base_classes = _app.load_model('base')
        cls.dia, cls.dia_classes = _app.load_model('dia')

    def test_every_letter_class_is_rendered_and_known(self):
        self.assertEqual(set(GLYPHS), set(self.base_classes))

    def test_feature_sizes_match_the_models(self):
        mask = np.zeros((56, 56), np.uint8)
        cv2.circle(mask, (28, 28), 15, 255, 3)
        self.assertEqual(_app.features(mask, 'base').shape[1], self.base.support_vectors.shape[1])
        self.assertEqual(_app.features(mask, 'dia').shape[1], self.dia.support_vectors.shape[1])

    def test_probabilities_are_a_distribution(self):
        mask = np.zeros((56, 56), np.uint8)
        cv2.line(mask, (10, 28), (46, 28), 255, 4)
        probabilities = self.base.predict_proba(_app.features(mask, 'base'))[0]
        self.assertEqual(len(probabilities), len(self.base_classes))
        self.assertAlmostEqual(float(probabilities.sum()), 1.0, places=4)
        self.assertTrue(np.all(probabilities >= 0))

    def test_prediction_is_a_valid_class_index(self):
        mask = np.zeros((56, 56), np.uint8)
        cv2.rectangle(mask, (15, 15), (40, 40), 255, 3)
        index = int(self.base.predict(_app.features(mask, 'base'))[0])
        self.assertIn(index, range(len(self.base_classes)))

    def test_empty_mask_does_not_crash(self):
        feats = _app.features(np.zeros((56, 56), np.uint8), 'base')
        self.assertTrue(np.all(np.isfinite(feats)))


if __name__ == '__main__':
    unittest.main(verbosity=2)
