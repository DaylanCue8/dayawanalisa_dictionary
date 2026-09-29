"""
CLASSIFICATION ACCURACY of the on-phone Baybayin SVM.

Runs every labelled glyph image through the SAME preprocessing, HOG and
model the app uses, and reports accuracy, per-class precision / recall /
F1 and a confusion matrix. NumPy + OpenCV only (no scikit-learn needed).

Dataset layout - one folder per class, any image type:

    DATASET/
        A/   img1.png img2.jpg ...
        Ba/  ...
        Da/  ...        (folders may also be named BA, DARA, da, ra ...)

Usage (from frontend/test_python, in the 'dayaw' conda env):

    python evaluate_classifier.py path/to/DATASET
    python evaluate_classifier.py path/to/DIA_DATASET --model dia
    python evaluate_classifier.py path/to/DATASET --out reports/base_eval

Writes to --out (default: reports/<model>_<date>):
    metrics.json, per_class.csv, confusion_matrix.csv, misclassified.csv,
    report.md
"""
import argparse
import csv
import datetime
import json
import os
import sys

import _app
from _app import np, cv2

IMAGE_EXTENSIONS = ('.png', '.jpg', '.jpeg', '.bmp', '.webp')

# Folder-name spellings seen in older reports/datasets -> app class name.
ALIASES = {
    'dara': 'Da', 'ra': 'Da', 'd': 'Da', 'r': 'Da',
    'e': 'EI', 'i': 'EI', 'ie': 'EI',
    'o': 'OU', 'u': 'OU', 'uo': 'OU',
    'ng': 'Nga',
    'dot': 'Dot', 'cross': 'Cross', 'x': 'X', 'virama': 'X',
}


def resolve_label(folder, classes):
    """Maps a folder name to one of the model's class names, or None."""
    key = folder.strip().lower().replace('_', '').replace('-', '').replace(' ', '')
    for name in classes:
        if name.lower() == key:
            return name
    alias = ALIASES.get(key)
    return alias if alias in classes else None


def load_dataset(root, classes):
    samples, skipped = [], []
    for folder in sorted(os.listdir(root)):
        path = os.path.join(root, folder)
        if not os.path.isdir(path):
            continue
        label = resolve_label(folder, classes)
        if label is None:
            skipped.append(folder)
            continue
        for name in sorted(os.listdir(path)):
            if name.lower().endswith(IMAGE_EXTENSIONS):
                samples.append((os.path.join(path, name), label))
    return samples, skipped


def evaluate(samples, model, classes, kind):
    index = {name: i for i, name in enumerate(classes)}
    n = len(classes)
    confusion = np.zeros((n, n), dtype=np.int64)   # rows = actual, cols = predicted
    wrong, unreadable, confidences = [], [], []
    for path, actual in samples:
        gray = cv2.imread(path, cv2.IMREAD_GRAYSCALE)
        if gray is None:
            unreadable.append(path)
            continue
        feats = _app.features(_app.image_to_ink_mask(gray), kind)
        predicted_index = int(model.predict(feats)[0])
        confidence = float(np.max(model.predict_proba(feats)[0]))
        predicted = classes[predicted_index]
        confusion[index[actual], predicted_index] += 1
        confidences.append(confidence)
        if predicted != actual:
            wrong.append((path, actual, predicted, confidence))
    return confusion, wrong, unreadable, confidences


def per_class_metrics(confusion, classes):
    rows = []
    for i, name in enumerate(classes):
        tp = int(confusion[i, i])
        support = int(confusion[i].sum())
        predicted = int(confusion[:, i].sum())
        precision = tp / predicted if predicted else 0.0
        recall = tp / support if support else 0.0
        f1 = 2 * precision * recall / (precision + recall) if precision + recall else 0.0
        rows.append(dict(cls=name, precision=precision, recall=recall, f1=f1, support=support))
    return rows


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('dataset', help='folder with one sub-folder per class')
    parser.add_argument('--model', choices=('base', 'dia'), default='base')
    parser.add_argument('--out', help='report folder (default: reports/<model>_<date>)')
    args = parser.parse_args(argv)
    args.dataset = _app.user_path(args.dataset)
    if args.out:
        args.out = _app.user_path(args.out)

    if not os.path.isdir(args.dataset):
        print(f'ERROR: dataset folder not found: {args.dataset}')
        return 2
    model, classes = _app.load_model(args.model)
    samples, skipped = load_dataset(args.dataset, classes)
    if skipped:
        print(f'WARNING: ignored folders that match no class: {", ".join(skipped)}')
    if not samples:
        print(f'ERROR: no labelled images found. Expected sub-folders named like: {", ".join(classes)}')
        return 2

    print(f'Evaluating {len(samples)} images with the app\'s {args.model} model ...')
    confusion, wrong, unreadable, confidences = evaluate(samples, model, classes, args.model)
    total = int(confusion.sum())
    correct = int(np.trace(confusion))
    accuracy = correct / total if total else 0.0
    rows = per_class_metrics(confusion, classes)
    present = [r for r in rows if r['support'] > 0]
    macro = {k: float(np.mean([r[k] for r in present])) for k in ('precision', 'recall', 'f1')}

    out = args.out or os.path.join(_app.HERE, 'reports', f'{args.model}_{datetime.date.today():%Y%m%d}')
    os.makedirs(out, exist_ok=True)
    metrics = dict(
        model=args.model, dataset=os.path.abspath(args.dataset), evaluated=total,
        correct=correct, accuracy=accuracy, macro_precision=macro['precision'],
        macro_recall=macro['recall'], macro_f1=macro['f1'],
        mean_confidence=float(np.mean(confidences)) if confidences else 0.0,
        unreadable_images=len(unreadable), classes=classes,
        date=datetime.datetime.now().isoformat(timespec='seconds'),
    )
    with open(os.path.join(out, 'metrics.json'), 'w', encoding='utf-8') as f:
        json.dump(metrics, f, indent=2)
    with open(os.path.join(out, 'per_class.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f)
        w.writerow(['class', 'precision', 'recall', 'f1', 'support'])
        for r in rows:
            w.writerow([r['cls'], f"{r['precision']:.4f}", f"{r['recall']:.4f}", f"{r['f1']:.4f}", r['support']])
    with open(os.path.join(out, 'confusion_matrix.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f)
        w.writerow(['actual \\ predicted'] + classes)
        for i, name in enumerate(classes):
            w.writerow([name] + [int(v) for v in confusion[i]])
    with open(os.path.join(out, 'misclassified.csv'), 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f)
        w.writerow(['image', 'actual', 'predicted', 'confidence'])
        for path, actual, predicted, conf in wrong:
            w.writerow([path, actual, predicted, f'{conf:.3f}'])

    lines = [
        f'# Classification accuracy - {args.model} model',
        '',
        f'- Images evaluated: **{total}** ({len(unreadable)} unreadable skipped)',
        f'- Correct: **{correct}**',
        f'- Accuracy: **{accuracy * 100:.2f}%**',
        f'- Macro precision / recall / F1: {macro["precision"] * 100:.2f}% / '
        f'{macro["recall"] * 100:.2f}% / {macro["f1"] * 100:.2f}%',
        f'- Mean confidence: {metrics["mean_confidence"] * 100:.1f}%',
        '',
        '| Class | Precision | Recall | F1 | Support |',
        '|---|---:|---:|---:|---:|',
    ] + [
        f'| {r["cls"]} | {r["precision"] * 100:.1f}% | {r["recall"] * 100:.1f}% | '
        f'{r["f1"] * 100:.1f}% | {r["support"]} |' for r in rows
    ]
    with open(os.path.join(out, 'report.md'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')

    print('\n'.join(lines))
    print(f'\nReports written to: {out}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
