"""
END-TO-END accuracy: whole photos through the app's full recognizer
(baybayin_offline.recognize - segmentation, classification, kudlit and
word-list disambiguation), compared with the expected Latin text.

Input: a CSV with a header row, paths relative to the CSV's folder:

    image,expected,input_type
    photos/bata.jpg,bata,marker
    photos/mahal_kita.jpg,mahal kita,pen

(input_type is optional; default 'marker'.)

    python evaluate_end_to_end.py path/to/labels.csv [--out reports/e2e]

Reports: exact-match accuracy (whole text right), character accuracy
(1 - character error rate, via edit distance), and how many photos ended
in each recognizer status (Success, Low_Confidence, Blurry_Image ...).
"""
import argparse
import csv
import datetime
import json
import os
import sys
from collections import Counter

import _app  # noqa: F401  (sets up the import path)
import baybayin_offline


def normalize(text):
    """Case-insensitive, whitespace-insensitive comparison. An ambiguous
    '{d/r}' slot (no word-list match) is kept as-is, so it counts as an
    error - the app did not commit to a letter."""
    return ' '.join(str(text).lower().split())


def edit_distance(a, b):
    previous = list(range(len(b) + 1))
    for i, ca in enumerate(a, 1):
        current = [i]
        for j, cb in enumerate(b, 1):
            current.append(min(previous[j] + 1, current[j - 1] + 1,
                               previous[j - 1] + (ca != cb)))
        previous = current
    return previous[-1]


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('labels_csv')
    parser.add_argument('--out', help='report folder (default: reports/e2e_<date>)')
    args = parser.parse_args(argv)
    args.labels_csv = _app.user_path(args.labels_csv)
    if args.out:
        args.out = _app.user_path(args.out)

    if not os.path.isfile(args.labels_csv):
        print(f'ERROR: labels file not found: {args.labels_csv}')
        return 2
    base = os.path.dirname(os.path.abspath(args.labels_csv))
    with open(args.labels_csv, newline='', encoding='utf-8-sig') as f:
        rows = list(csv.DictReader(f))
    if not rows or not {'image', 'expected'} <= set(rows[0]):
        print('ERROR: the CSV needs a header row with at least: image,expected')
        return 2

    results, statuses = [], Counter()
    exact = char_errors = char_total = 0
    for row in rows:
        path = os.path.join(base, row['image'])
        expected = normalize(row['expected'])
        try:
            with open(path, 'rb') as f:
                reply = json.loads(baybayin_offline.recognize(f.read(), row.get('input_type') or 'marker'))
        except OSError as e:
            reply = {'status': 'File_Error', 'error': str(e)}
        status = reply.get('status', 'Error')
        predicted = normalize(reply.get('translated_text', '')) if 'error' not in reply else ''
        statuses[status] += 1
        errors = edit_distance(predicted, expected)
        exact += predicted == expected
        char_errors += errors
        char_total += max(len(expected), 1)
        results.append(dict(image=row['image'], expected=expected, predicted=predicted,
                            status=status, char_errors=errors,
                            confidence=reply.get('confidence', 0)))
        print(f'{"OK " if predicted == expected else "   "} {row["image"]}: '
              f'"{predicted}" (expected "{expected}", {status})')

    total = len(results)
    metrics = dict(
        photos=total, exact_match=exact, exact_match_accuracy=exact / total,
        character_accuracy=max(0.0, 1 - char_errors / char_total),
        character_error_rate=char_errors / char_total, statuses=dict(statuses),
        date=datetime.datetime.now().isoformat(timespec='seconds'),
    )
    out = args.out or os.path.join(_app.HERE, 'reports', f'e2e_{datetime.date.today():%Y%m%d}')
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, 'metrics.json'), 'w', encoding='utf-8') as f:
        json.dump(metrics, f, indent=2)
    with open(os.path.join(out, 'results.csv'), 'w', newline='', encoding='utf-8') as f:
        writer = csv.DictWriter(f, fieldnames=list(results[0]))
        writer.writeheader()
        writer.writerows(results)

    print(f'\nPhotos: {total}')
    print(f'Exact-match accuracy: {metrics["exact_match_accuracy"] * 100:.2f}% ({exact}/{total})')
    print(f'Character accuracy:   {metrics["character_accuracy"] * 100:.2f}%')
    print(f'Statuses: {dict(statuses)}')
    print(f'Reports written to: {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
