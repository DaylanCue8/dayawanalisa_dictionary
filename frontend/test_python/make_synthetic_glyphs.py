"""
Renders the 17 base Baybayin letters from the app's font into a labelled
folder, with small random rotation / size / stroke changes.

PURPOSE: a smoke test that evaluate_classifier.py runs end to end. It is
NOT a measure of real accuracy - font glyphs are not handwriting. Report
accuracy only from real, held-out handwritten samples.

    python make_synthetic_glyphs.py            # -> synthetic_glyphs/, 10 per class
    python make_synthetic_glyphs.py --per-class 30 --out my_folder
"""
import argparse
import os
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

HERE = os.path.dirname(os.path.abspath(__file__))
FONT = os.path.join(HERE, '..', 'assets', 'fonts', 'baybayin_custom.ttf')

# classes.json base class -> the Unicode letter the font draws for it
GLYPHS = {
    'A': 'ᜀ', 'EI': 'ᜁ', 'OU': 'ᜂ', 'Ka': 'ᜃ', 'Ga': 'ᜄ',
    'Nga': 'ᜅ', 'Ta': 'ᜆ', 'Da': 'ᜇ', 'Na': 'ᜈ', 'Pa': 'ᜉ',
    'Ba': 'ᜊ', 'Ma': 'ᜋ', 'Ya': 'ᜌ', 'La': 'ᜎ', 'Wa': 'ᜏ',
    'Sa': 'ᜐ', 'Ha': 'ᜑ',
}


def render(char, rng):
    font = ImageFont.truetype(FONT, rng.randint(90, 140))
    canvas = Image.new('L', (240, 240), 255)
    draw = ImageDraw.Draw(canvas)
    stroke = rng.choice([0, 0, 1, 2])
    draw.text((120, 120), char, font=font, fill=0, anchor='mm',
              stroke_width=stroke, stroke_fill=0)
    canvas = canvas.rotate(rng.uniform(-8, 8), fillcolor=255)
    if rng.random() < 0.5:
        canvas = canvas.filter(ImageFilter.GaussianBlur(rng.uniform(0.3, 1.0)))
    return canvas


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--out', default=os.path.join(HERE, 'synthetic_glyphs'))
    parser.add_argument('--per-class', type=int, default=10)
    parser.add_argument('--seed', type=int, default=7)
    args = parser.parse_args()
    rng = random.Random(args.seed)
    for cls, char in GLYPHS.items():
        folder = os.path.join(args.out, cls)
        os.makedirs(folder, exist_ok=True)
        for i in range(args.per_class):
            render(char, rng).save(os.path.join(folder, f'{cls}_{i:03d}.png'))
    print(f'Wrote {len(GLYPHS) * args.per_class} images to {args.out}')


if __name__ == '__main__':
    main()
