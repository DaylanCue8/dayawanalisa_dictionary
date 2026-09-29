# Dayaw – White-Box Testing Guide

How to run and present the four white-box criteria. All commands run from
the `frontend/` folder. Python commands use the `dayaw` conda environment
(it has NumPy and OpenCV):

```powershell
cd C:\xampp\htdocs\V6_DAYAW\frontend
$py = "C:\Users\RAIN\miniconda3\envs\dayaw\python.exe"
```

| Criterion | Command | Result on 2026-09-30 |
|---|---|---|
| 1. Rule-based consistency | `flutter test test/rule_consistency_test.dart test/tagalog_to_baybayin_local_translator_test.dart` | 9 rules × 43,280 words, **0 violations** |
| 2. Statement coverage | `flutter test --coverage` then `dart run tool/coverage_summary.dart` | **99.4%** (516 / 519 lines) of the logic files |
| 3. Classification accuracy | `& $py test_python/evaluate_classifier.py <dataset>` | Needs your held-out handwriting set (see below) |
| 4. Error handling | `flutter test test/recognition_test.dart test/app_settings_test.dart test/multi_page_and_export_test.dart` and `cd test_python; & $py -m unittest -v test_recognizer` | **121 Dart + 15 Python tests pass** |

Run everything at once with `flutter test` (121 tests).

---

## 1. Rule-based consistency

The Filipino → Baybayin engine (`lib/services/tagalog_to_baybayin_local_translator.dart`)
is rule-based and deterministic, so the same rules must hold for every input.
`test/rule_consistency_test.dart` checks them on **every word of the app's
Tagalog word list** (43,280 unique words, 196,066 syllable pieces):

| Rule | What must hold |
|---|---|
| R1 | Same input → same output and confidence (determinism) |
| R2 | `translate()` equals the syllable breakdown joined together |
| R3 | Output contains only Baybayin letters/marks, dandas and spaces |
| R4 | Confidence = 100 − 15 × (number of c/f/j/q/v/x/z), never below 0 |
| R5 | Consonant + e/i ends in kudlit-I; + o/u in kudlit-U; + a has no mark |
| R6 | A consonant with no vowel ends in the virama |
| R7 | Lone vowels: a → ᜀ, e/i → ᜁ, o/u → ᜂ |
| R8 | D and R always give the same letter (allophones) |
| R9 | "ng" is one letter (ᜅ), never n + g |

`test/tagalog_to_baybayin_local_translator_test.dart` adds 32 hand-written
cases (each kudlit, *mga*, punctuation, the confidence penalty, the full
consonant table).

Also consistency-checked:
- The legal notices: every section has the same number of English and
  Filipino paragraphs (`test/language_and_notices_test.dart`).
- The recognizer: the same photo always gives the same result
  (`test_python/test_recognizer.py`).

## 2. Statement coverage

```powershell
flutter test --coverage
dart run tool/coverage_summary.dart                       # logic files
dart run tool/coverage_summary.dart --out coverage/summary.md
dart run tool/coverage_summary.dart --all                 # every file tests load
```

| File | Coverage |
|---|---:|
| `tagalog_to_baybayin_local_translator.dart` (rule engine) | 100% |
| `recognition_outcome.dart` (reading recognizer replies) | 100% |
| `offline_recognizer.dart` (Flutter ↔ Python bridge) | 100% |
| `app_settings.dart` | 100% |
| `app_language.dart` | 100% |
| `legal_screen.dart` | 100% |
| `result_exporter.dart` | 98.9% |
| **Total** | **99.4%** |

The 3 uncovered lines in `result_exporter.dart` are the calls into the real
share sheet and PDF renderer (native Android code), plus a private
constructor. Unit tests replace those two calls with fakes, so everything
around them is covered. The calls themselves are checked on a phone (see
the manual checklist below).

**Note on the rule engine:** it previously had lines that could never run.
The lone-vowel branch was unreachable because of the regex order, so 100%
was impossible. It was refactored so every line is reachable. The new
version gives **identical output** to the old one on all 69,078 inputs
tested (the word-list lines plus edge cases).

Screen layout code (widgets) isn't a white-box target. The screens' logic
was moved into the files above so it can be tested.

## 3. Classification accuracy

`test_python/evaluate_classifier.py` runs every labelled image through
**the same code the phone uses**: the same cropping and framing
(`normalize_for_model`), the same HOG settings, and the same `.npz` SVM
models. The number it reports describes the real app.

1. Collect **held-out** handwritten samples: images that were *not* used in
   training. Put one folder per class:
   ```
   my_test_set/
     A/  Ba/  Da/  EI/  Ga/  Ha/  Ka/  La/  Ma/  Na/  Nga/  OU/  Pa/  Sa/  Ta/  Wa/  Ya/
   ```
   Folder names are matched loosely: `BA`, `DARA`, `ra`, `NG` and so on
   work too.
2. Run:
   ```powershell
   & $py test_python/evaluate_classifier.py path\to\my_test_set
   & $py test_python/evaluate_classifier.py path\to\kudlit_set --model dia   # Dot / Cross / X
   ```
3. The script writes these files to `test_python/reports/<model>_<date>/`:
   - `report.md`: accuracy, macro precision/recall/F1, and a per-class table
   - `confusion_matrix.csv`: for a confusion-matrix figure
   - `misclassified.csv`: every wrong image, for the error analysis

**Whole photos (end to end):** make a CSV of `image,expected[,input_type]`
and run `& $py test_python/evaluate_end_to_end.py labels.csv`. It reports
exact-match accuracy, character accuracy (1 − character error rate) and
how many photos ended in each status.

**About the old report:** the old `backend/tests/reports/model_metrics.json`
shows 4.7% accuracy. That is chance level for 17 classes, a sign that the
evaluation was wrong, not the model. Its class names (`BA`, `DARA`) don't
match the model's (`Ba`, `Da`), and `backend/btt_test.py` uses a different
HOG setup (64×64) from the app (56×56 with its own framing). Don't cite that
number. Use the new script instead.

**Smoke test only:** `make_synthetic_glyphs.py` renders the 17 letters from
the app's font. The classifier scores 100% on them. That proves the pipeline
and label mapping are wired correctly. It is **not** a handwriting accuracy
result, so don't report it as one.

## 4. Error handling

Every failure has a defined, tested outcome. Nothing crashes, and each case
shows the user a clear message.

| Failure | Where it's handled | Test |
|---|---|---|
| Empty, corrupt or truncated image | Python: status `Invalid_Image`; app: "That image could not be opened" | `test_recognizer.py`, `recognition_test.dart` |
| Blurry photo | Camera blur check + Python `Blurry_Image` → "too blurry" message | `test_recognizer.py` |
| Blank page / no letters | `No_Characters` → "No Baybayin letters found" | both |
| Python crash, plugin missing, `PlatformException` | Bridge returns null → "Could not process the image" | `recognition_test.dart` |
| Python never answers | 60 s timeout → same message, spinner stops | `recognition_test.dart` |
| Malformed or non-object JSON reply | Returns null, never throws | `recognition_test.dart` |
| Unknown status from a future recognizer | Treated as failed | `recognition_test.dart` |
| Malformed bounding box or confidence | Removed or zeroed once, at the entry point, so screens can't crash | `recognition_test.dart` |
| One page fails in a multi-page scan | Marked unread; the other pages continue; "2 of 6 pages could not be read" | `multi_page_and_export_test.dart` |
| More than 10 pages | Camera locks at 10 with a dialog; scan tab caps at 10 | manual (camera) |
| Corrupted or old saved settings | Each bad value falls back to its own default; out-of-range values are clamped | `app_settings_test.dart` |
| Phone storage fails (read, write, reset) | App keeps working with values in memory | `app_settings_test.dart` |
| Export of a broken image | Throws, and the result screen shows "Could not export …" | `multi_page_and_export_test.dart` |
| Share sheet fails | Error reaches the screen's message | `multi_page_and_export_test.dart` |
| Unsupported letters or emoji in Filipino text | Dropped, confidence reduced, no crash | `rule_consistency_test.dart` |

## Manual device checklist

These parts need a real phone: the camera, Android's share sheet and PDF
renderer, and Python running on the phone. Run them on the release APK
with **airplane mode on**:

- [ ] Scan one page (marker, then pen) → result and breakdown appear
- [ ] Scan a blurry photo → "too blurry" message
- [ ] Multi-page: 3 pages → combined result; 10 pages → limit dialog, shutter locked
- [ ] Export JPG, PNG, PDF and TXT → each opens the share sheet; save to Files and open it
- [ ] Switch language → every screen changes; restart the app → it stays
- [ ] Settings → Privacy & Data and Terms of Use open in both languages
- [ ] First launch: the intro's last page shows the Terms / Privacy links
