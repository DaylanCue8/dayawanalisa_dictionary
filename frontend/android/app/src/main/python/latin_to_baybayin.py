# =====================================================================
# DAYAW - LATIN-TO-BAYBAYIN SERVICE  (latin_to_baybayin.py)
# ---------------------------------------------------------------------
# Photo of handwritten Latin (printed letters)  ->  Baybayin text.
#
# Same front half as the Baybayin pen service (copied unchanged below):
#   decode + EXIF -> blur check -> enhance (denoise, CLAHE, sharpen)
#   -> illumination normalization -> Otsu -> deskew -> line bands
#   -> per-line masks -> glyph segmentation -> word grouping
#
# Latin-specific back half:
#   - narrow merge kernel (Latin letters sit closer together than
#     Baybayin glyphs, so a wide kernel would glue neighbours together)
#   - the i-dot is kept with its stem (merge_stray_diacritic_boxes)
#   - touching letters: recognition-based splitting - every way of cutting
#     a wide box is scored by the SVM and the most confident cut wins
#   - each letter: normalize_for_model (56x56, 12% margin) -> HOG 8x8/2x2
#     -> Latin RBF SVM (19 classes) with probability
#   - optional dictionary correction using each letter's 2nd-best guess
#     (fixes I/l, u/n ... when the word is not a real Filipino word)
#   - letters -> syllables -> Baybayin (b+a = BA, ng = NGA, final
#     consonant = consonant + krus-kudlit)
#
# The app only needs:
#   warm_up_latin()                  (once - loads model_latin.npz + latin_classes.json)
#   recognize_latin_json(image_bytes) (per photo)
#
# Like the Baybayin side, the phone needs NO scikit-learn / scikit-image:
# HOG and the RBF SVM run in plain NumPy (numpy_hog + OfflineSVC, copied
# unchanged from the team's export script, which checks they match).
# =====================================================================
import base64
import io
import json
import os
import re
from itertools import product

import cv2
import numpy as np
from PIL import Image as PILImage, ImageOps


# =====================================================================
# SHARED PREPROCESSING - copied UNCHANGED from the Baybayin pen service
# so both directions use exactly the same image pipeline.
# =====================================================================
def decode_grayscale_exif_corrected(image_bytes):
    pil_img = PILImage.open(io.BytesIO(image_bytes))
    pil_img = ImageOps.exif_transpose(pil_img)
    pil_img = pil_img.convert('L')
    return np.array(pil_img)
BLUR_RESIZE_WIDTH = 800
BLUR_VARIANCE_THRESHOLD = 60.0
BLURRY_IMAGE_MESSAGE = (
    'Image too blurry to process. Please hold the phone steady, '
    'ensure good lighting, and retake the photo.'
)


def compute_blur_score(gray_img, resize_width=BLUR_RESIZE_WIDTH):
    """
    Higher score = sharper. Resizing to a fixed width first keeps the
    score comparable across different camera resolutions.
    """
    height, width = gray_img.shape[:2]
    if width > resize_width:
        scale = resize_width / float(width)
        gray_img = cv2.resize(gray_img, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    return float(cv2.Laplacian(gray_img, cv2.CV_64F).var())
MIN_LONG_SIDE_PX = 1000


def enhance_image_quality(gray_img):
    """
    Recovers usable ink detail from a low-quality phone photo before it
    goes into Otsu binarization. Denoise first so CLAHE doesn't amplify
    noise, then sharpen last so the unsharp mask sharpens real edges.
    """
    height, width = gray_img.shape[:2]
    long_side = max(height, width)
    if long_side < MIN_LONG_SIDE_PX:
        scale = MIN_LONG_SIDE_PX / float(long_side)
        gray_img = cv2.resize(
            gray_img, None, fx=scale, fy=scale, interpolation=cv2.INTER_CUBIC
        )

    denoised = cv2.fastNlMeansDenoising(
        gray_img, h=7, templateWindowSize=7, searchWindowSize=21
    )
    clahe = cv2.createCLAHE(clipLimit=2.0, tileGridSize=(8, 8))
    contrasted = clahe.apply(denoised)
    blurred = cv2.GaussianBlur(contrasted, (0, 0), sigmaX=3)
    sharpened = cv2.addWeighted(contrasted, 1.5, blurred, -0.5, 0)
    return sharpened


def preprocess_image(gray_img):
    _, thresh = cv2.threshold(
        gray_img, 0, 255, cv2.THRESH_BINARY_INV + cv2.THRESH_OTSU
    )
    return thresh


def _estimate_stroke_thickness(binary_img):
    dist = cv2.distanceTransform(binary_img, cv2.DIST_L2, 5)
    nonzero_dists = dist[binary_img > 0]
    if nonzero_dists.size == 0:
        return 1.0
    typical_half_width = float(np.percentile(nonzero_dists, 50))
    return max(typical_half_width * 2.0, 1.0)
DESKEW_ANGLE_RANGE_DEGREES = 15.0
DESKEW_ANGLE_STEP_DEGREES = 0.5


def estimate_skew_angle(binary_img, angle_range=DESKEW_ANGLE_RANGE_DEGREES,
                         angle_step=DESKEW_ANGLE_STEP_DEGREES):
    height, width = binary_img.shape[:2]
    center = (width / 2.0, height / 2.0)
    best_angle = 0.0
    best_score = -1.0
    angle = -angle_range
    while angle <= angle_range + 1e-9:
        rotation_matrix = cv2.getRotationMatrix2D(center, angle, 1.0)
        rotated = cv2.warpAffine(
            binary_img, rotation_matrix, (width, height),
            flags=cv2.INTER_NEAREST, borderValue=0,
        )
        row_profile = rotated.sum(axis=1).astype(np.float64)
        score = float(row_profile.var())
        if score > best_score:
            best_score = score
            best_angle = angle
        angle += angle_step
    return best_angle


def _invert_point(rotation_matrix_inv, x, y):
    nx = rotation_matrix_inv[0][0] * x + rotation_matrix_inv[0][1] * y + rotation_matrix_inv[0][2]
    ny = rotation_matrix_inv[1][0] * x + rotation_matrix_inv[1][1] * y + rotation_matrix_inv[1][2]
    return nx, ny


def map_box_to_original(rotation_matrix_inv, x0, y0, x1, y1):
    corners = [(x0, y0), (x1, y0), (x0, y1), (x1, y1)]
    mapped = [_invert_point(rotation_matrix_inv, x, y) for x, y in corners]
    xs = [p[0] for p in mapped]
    ys = [p[1] for p in mapped]
    return min(xs), min(ys), max(xs), max(ys)
LINE_BAND_SMOOTH_FRAC = 0.02
LINE_BAND_RUN_FRAC = 0.3
LINE_BAND_MERGE_GAP_FRAC = 0.6
LINE_BAND_MIN_GAP_PX = 5
LINE_BAND_EXPAND_FRAC = 0.5


def _row_letter_counts(binary_img):
    """
    For each row, counts how many SEPARATE horizontal ink segments it
    passes through - i.e. how many distinct letters/strokes intersect
    that row, not how many ink pixels it has.
    """
    has_ink = binary_img > 0
    padded = np.pad(has_ink, ((0, 0), (1, 1)), mode='constant', constant_values=False)
    rising_edges = np.diff(padded.astype(np.int8), axis=1) == 1
    return rising_edges.sum(axis=1)


def find_line_bands(binary_img, run_frac=LINE_BAND_RUN_FRAC,
                     smooth_frac=LINE_BAND_SMOOTH_FRAC,
                     merge_gap_frac=LINE_BAND_MERGE_GAP_FRAC,
                     min_gap_px=LINE_BAND_MIN_GAP_PX,
                     expand_frac=LINE_BAND_EXPAND_FRAC):
    """
    Returns a list of (y0, y1) bands, one per detected text line.

    Each core band is expanded, then SNAPPED outward to the nearest row
    with zero ink (never past the midpoint shared with the neighboring
    line), so a band boundary can never cut through a diacritic that
    hangs further from its base than usual.
    """
    row_profile = _row_letter_counts(binary_img).astype(np.float64)
    if row_profile.max() <= 0:
        return []

    height = len(row_profile)
    smooth_size = max(3, int(round(height * smooth_frac)) | 1)
    kernel = np.ones(smooth_size, dtype=np.float64) / smooth_size
    smoothed = np.convolve(row_profile, kernel, mode='same')

    threshold = smoothed.max() * run_frac
    row_is_core_text = smoothed > threshold

    runs = []
    start = None
    for i, is_core in enumerate(row_is_core_text):
        if is_core and start is None:
            start = i
        elif not is_core and start is not None:
            runs.append((start, i))
            start = None
    if start is not None:
        runs.append((start, height))
    if not runs:
        return []

    median_height = float(np.median([end - start for start, end in runs]))
    merge_gap_threshold = max(min_gap_px, median_height * merge_gap_frac)

    merged = [list(runs[0])]
    for start, end in runs[1:]:
        prev_start, prev_end = merged[-1]
        if start - prev_end <= merge_gap_threshold:
            merged[-1][1] = end
        else:
            merged.append([start, end])

    has_ink_per_row = (binary_img > 0).any(axis=1)

    def _snap_to_blank_row(candidate_idx, direction, limit):
        idx = candidate_idx
        while (idx > limit) if direction == -1 else (idx < limit):
            if not has_ink_per_row[idx]:
                return idx
            idx += direction
        return limit

    expand = max(min_gap_px, int(round(median_height * expand_frac)))
    bands = []
    for idx, (start, end) in enumerate(merged):
        midpoint_prev = (merged[idx - 1][1] + start) // 2 if idx > 0 else 0
        midpoint_next = (
            (end + merged[idx + 1][0]) // 2 if idx + 1 < len(merged) else height
        )
        band_y0_candidate = max(midpoint_prev, start - expand)
        band_y1_candidate = min(midpoint_next, end + expand)
        band_y0 = _snap_to_blank_row(band_y0_candidate, -1, midpoint_prev)
        band_y1 = _snap_to_blank_row(band_y1_candidate, 1, midpoint_next)
        bands.append((band_y0, band_y1))
    return bands


def split_into_line_masks(binary_img, bands):
    """
    Assigns every connected ink component to exactly ONE line band and
    returns one full-size mask per band.

    Slicing the image by rows (binary[y0:y1]) can cut straight through
    a cross kudlit that hangs between two tightly spaced lines: half of
    it stays with its letter and the other half lands in the next line
    as a stray fragment. Assigning whole components avoids that - a
    mark is never divided between lines.

    A component goes to the band it overlaps most. If it lies entirely
    in a gap between bands, it goes to the band whose center is nearest.
    """
    if not bands:
        return []
    num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(
        binary_img, connectivity=8
    )
    component_band = np.full(num_labels, -1, dtype=np.int32)
    band_centers = [(b0 + b1) / 2.0 for b0, b1 in bands]
    for i in range(1, num_labels):
        top = int(stats[i, cv2.CC_STAT_TOP])
        bottom = top + int(stats[i, cv2.CC_STAT_HEIGHT])
        overlaps = [min(bottom, b1) - max(top, b0) for b0, b1 in bands]
        if max(overlaps) > 0:
            component_band[i] = int(np.argmax(overlaps))
        else:
            center = (top + bottom) / 2.0
            component_band[i] = int(np.argmin([abs(center - c) for c in band_centers]))
    band_map = component_band[labels]
    return [np.where(band_map == k, 255, 0).astype(np.uint8) for k in range(len(bands))]


def otsu_1d_threshold(gaps):
    """
    Finds the optimal threshold separating small letter gaps from large
    word gaps using Otsu's method on 1D gap values.
    """
    if len(gaps) < 2:
        return 10.0

    gaps = np.array(gaps)
    min_g, max_g = gaps.min(), gaps.max()

    # If all gaps are virtually identical, there are no word spaces
    if max_g - min_g < 5:
        return max_g + 1.0

    thresholds = np.linspace(min_g, max_g, 50)
    best_thresh = thresholds[0]
    best_variance = -1

    for t in thresholds:
        bg = gaps[gaps <= t]  # Letter gaps
        fg = gaps[gaps > t]   # Word gaps

        if len(bg) == 0 or len(fg) == 0:
            continue

        w0 = len(bg) / len(gaps)
        w1 = len(fg) / len(gaps)
        var_between = w0 * w1 * ((bg.mean() - fg.mean()) ** 2)

        if var_between > best_variance:
            best_variance = var_between
            best_thresh = t

    return best_thresh
SEGMENT_MERGE_WIDTH_MULTIPLIER = 2.0
SEGMENT_MERGE_HEIGHT_MULTIPLIER = 14.0
SEGMENT_MERGE_MIN_WIDTH = 5
SEGMENT_MERGE_MAX_WIDTH = 15
SEGMENT_MERGE_MIN_HEIGHT = 35
SEGMENT_MERGE_MAX_HEIGHT = 70


def estimate_segment_merge_kernel(bin_img):
    thickness = _estimate_stroke_thickness(bin_img)
    width = int(round(thickness * SEGMENT_MERGE_WIDTH_MULTIPLIER))
    height = int(round(thickness * SEGMENT_MERGE_HEIGHT_MULTIPLIER))
    width = max(SEGMENT_MERGE_MIN_WIDTH, min(width, SEGMENT_MERGE_MAX_WIDTH))
    height = max(SEGMENT_MERGE_MIN_HEIGHT, min(height, SEGMENT_MERGE_MAX_HEIGHT))
    return (width, height)


def segment_glyphs(bin_img, pad=0, min_area=40, merge_kernel=(5, 35)):
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, merge_kernel)
    dilated = cv2.dilate(bin_img, kernel, iterations=1)
    contours, _ = cv2.findContours(
        dilated, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
    )

    boxes = []
    height, width = bin_img.shape[:2]
    for contour in contours:
        x, y, box_width, box_height = cv2.boundingRect(contour)
        if box_width * box_height < min_area:
            continue
        boxes.append((
            max(0, x - pad), max(0, y - pad),
            min(width, x + box_width + pad),
            min(height, y + box_height + pad),
        ))

    if not boxes:
        return []

    boxes.sort(key=lambda box: box[1])
    rows = [[boxes[0]]]
    for box in boxes[1:]:
        previous = rows[-1][-1]
        previous_center = (previous[1] + previous[3]) / 2
        current_center = (box[1] + box[3]) / 2
        row_height = previous[3] - previous[1]
        if abs(current_center - previous_center) < row_height * 0.5:
            rows[-1].append(box)
        else:
            rows.append([box])

    return [box for row in rows for box in sorted(row, key=lambda item: item[0])]


def tighten_boxes(bin_img, boxes, pad=0):
    height, width = bin_img.shape[:2]
    tightened = []
    for x0, y0, x1, y1 in boxes:
        sub = bin_img[y0:y1, x0:x1]
        ys, xs = np.where(sub > 0)
        if len(xs) == 0:
            tightened.append((x0, y0, x1, y1))
            continue
        tightened.append((
            max(0, x0 + xs.min() - pad),
            max(0, y0 + ys.min() - pad),
            min(width, x0 + xs.max() + 1 + pad),
            min(height, y0 + ys.max() + 1 + pad),
        ))
    return tightened
MODEL_INPUT_SIZE = 56
MODEL_MARGIN_FRAC = 0.12


def normalize_for_model(mask, margin_frac=MODEL_MARGIN_FRAC, size=MODEL_INPUT_SIZE):
    """Returns a 56x56 uint8 white-on-black image framed like the training set."""
    coords = cv2.findNonZero(mask)
    if coords is None:
        return np.zeros((size, size), dtype=np.uint8)
    x, y, w, h = cv2.boundingRect(coords)
    crop = mask[y:y + h, x:x + w]
    margin = int(margin_frac * max(w, h))
    side = max(w, h) + 2 * margin
    square = np.zeros((side, side), dtype=np.uint8)
    y_off, x_off = (side - h) // 2, (side - w) // 2
    square[y_off:y_off + h, x_off:x_off + w] = crop
    return cv2.resize(square, (size, size), interpolation=cv2.INTER_AREA)
DIACRITIC_MERGE_MIN_HORIZONTAL_OVERLAP_FRAC = 0.3
DIACRITIC_MERGE_MAX_VERTICAL_GAP_MULTIPLIER = 3.0
DIACRITIC_MERGE_ABSOLUTE_GAP_CAP_MULTIPLIER = 2.5
DIACRITIC_MERGE_SIZE_RATIO_THRESHOLD = 0.45


def _boxes_horizontal_overlap_frac(box_a, box_b):
    ax0, _, ax1, _ = box_a
    bx0, _, bx1, _ = box_b
    overlap = max(0, min(ax1, bx1) - max(ax0, bx0))
    smaller_width = min(ax1 - ax0, bx1 - bx0)
    if smaller_width <= 0:
        return 0.0
    return overlap / smaller_width


def _boxes_vertical_gap(box_a, box_b):
    _, ay0, _, ay1 = box_a
    _, by0, _, by1 = box_b
    if ay1 <= by0:
        return by0 - ay1
    if by1 <= ay0:
        return ay0 - by1
    return 0.0


def merge_stray_diacritic_boxes(boxes,
                                 min_horizontal_overlap_frac=DIACRITIC_MERGE_MIN_HORIZONTAL_OVERLAP_FRAC,
                                 max_vertical_gap_multiplier=DIACRITIC_MERGE_MAX_VERTICAL_GAP_MULTIPLIER,
                                 absolute_gap_cap_multiplier=DIACRITIC_MERGE_ABSOLUTE_GAP_CAP_MULTIPLIER,
                                 size_ratio_threshold=DIACRITIC_MERGE_SIZE_RATIO_THRESHOLD):
    if len(boxes) <= 1:
        return list(boxes)

    heights = [b[3] - b[1] for b in boxes]
    median_height = float(np.median(heights)) if heights else 1.0
    absolute_gap_cap = median_height * absolute_gap_cap_multiplier

    current_boxes = list(boxes)
    merged_any = True
    while merged_any:
        merged_any = False
        n = len(current_boxes)
        for i in range(n):
            if current_boxes[i] is None:
                continue
            for j in range(n):
                if i == j or current_boxes[j] is None:
                    continue

                box_i = current_boxes[i]
                box_j = current_boxes[j]
                area_i = (box_i[2] - box_i[0]) * (box_i[3] - box_i[1])
                area_j = (box_j[2] - box_j[0]) * (box_j[3] - box_j[1])
                bigger_area = max(area_i, area_j)
                smaller_area = min(area_i, area_j)
                if bigger_area == 0 or smaller_area / bigger_area > size_ratio_threshold:
                    continue

                overlap_frac = _boxes_horizontal_overlap_frac(box_i, box_j)
                if overlap_frac < min_horizontal_overlap_frac:
                    continue

                bigger_box = box_i if area_i >= area_j else box_j
                bigger_height = bigger_box[3] - bigger_box[1]
                gap_limit = min(bigger_height * max_vertical_gap_multiplier, absolute_gap_cap)
                gap = _boxes_vertical_gap(box_i, box_j)
                if gap > gap_limit:
                    continue

                merged_box = (
                    min(box_i[0], box_j[0]), min(box_i[1], box_j[1]),
                    max(box_i[2], box_j[2]), max(box_i[3], box_j[3]),
                )
                current_boxes[i] = merged_box
                current_boxes[j] = None
                merged_any = True
                break
            if merged_any:
                break

    return [b for b in current_boxes if b is not None]
ORPHAN_FRAGMENT_MIN_FRAC = 0.35


def drop_orphan_fragments(boxes, min_frac=ORPHAN_FRAGMENT_MIN_FRAC):
    if len(boxes) < 3:
        return list(boxes)
    median_height = float(np.median([y1 - y0 for _, y0, _, y1 in boxes]))
    median_width = float(np.median([x1 - x0 for x0, _, x1, _ in boxes]))
    return [
        box for box in boxes
        if not ((box[3] - box[1]) < min_frac * median_height
                and (box[2] - box[0]) < min_frac * median_width)
    ]


# =====================================================================
# LATIN-SPECIFIC SEGMENTATION
# =====================================================================
# Latin letters are written closer together than Baybayin glyphs, so the
# horizontal part of the merge kernel is kept very small (it only closes
# hairline breaks). The vertical part is the same as Baybayin, which is
# what joins the dot of 'i' to its stem.
LATIN_MERGE_MAX_WIDTH = 3

# A box much taller than the letters on its line is not a letter (the edge
# of the paper, a shadow line, a fold) - it is dropped.
TOO_TALL_FACTOR = 2.0


def drop_too_tall_boxes(boxes, factor=TOO_TALL_FACTOR):
    if len(boxes) < 3:
        return list(boxes)
    median_h = float(np.median([b[3] - b[1] for b in boxes]))
    return [b for b in boxes if (b[3] - b[1]) <= factor * median_h]


# ---- Latin segmentation: one box per separate mark, dots go to their stem ----
# The Baybayin-style segmentation stretches every mark up and down (a tall
# merge kernel) so the i-dot reaches its stem. With slanted handwriting that
# also glues neighbours: the bottom of a slanted 'l' ends right beside the
# dot of the next 'i', so "li" became ONE box. Here every connected mark is
# its own box, and a small mark (the i-dot) is joined only to the mark
# BELOW it that it overlaps most.
DOT_MAX_HEIGHT_FRAC = 0.45    # x median mark height: smaller marks may be dots
DOT_SIDE_REACH = 0.25         # x median height: a dot may sit this far left/right of its stem
DOT_MAX_GAP = 0.8             # x median height: largest gap between a dot and its stem
SEG_MIN_AREA = 10             # pixels: smaller marks are noise


def segment_latin_glyphs(bin_img, min_area=SEG_MIN_AREA):
    """Returns tight boxes (x0, y0, x1, y1), left to right."""
    n, _, stats, _ = cv2.connectedComponentsWithStats(bin_img, connectivity=8)
    boxes = [(int(x), int(y), int(x + w), int(y + h))
             for x, y, w, h, a in stats[1:] if a >= min_area]
    if len(boxes) < 2:
        return boxes
    med = float(np.median([b[3] - b[1] for b in boxes]))
    is_dot = [(b[3] - b[1]) < DOT_MAX_HEIGHT_FRAC * med and (b[2] - b[0]) < 0.8 * med
              for b in boxes]
    owner = list(range(len(boxes)))
    for i, d in enumerate(boxes):
        if not is_dot[i]:
            continue
        reach = DOT_SIDE_REACH * med
        best, best_score = None, None
        for j, b in enumerate(boxes):
            if j == i or is_dot[j]:
                continue
            overlap = min(d[2] + reach, b[2]) - max(d[0] - reach, b[0])
            below = (b[1] + b[3]) / 2.0 > (d[1] + d[3]) / 2.0
            gap = b[1] - d[3]
            if overlap <= 0 or not below or gap > DOT_MAX_GAP * med:
                continue
            # most real overlap first (no reach), then the nearest
            real = min(d[2], b[2]) - max(d[0], b[0])
            score = (real, -abs((b[0] + b[2]) - (d[0] + d[2])))
            if best_score is None or score > best_score:
                best, best_score = j, score
        if best is not None:
            owner[i] = best
    groups = {}
    for i, o in enumerate(owner):
        groups.setdefault(o, []).append(boxes[i])
    merged = [(min(b[0] for b in g), min(b[1] for b in g),
               max(b[2] for b in g), max(b[3] for b in g)) for g in groups.values()]
    return sorted(merged, key=lambda b: b[0])


# =====================================================================
# "IS THIS HANDWRITING ON PAPER?" CHECKS - copied UNCHANGED from the
# Baybayin pen service (same functions, same limits), so both directions
# ignore rooms, furniture, tables and stains the same way.
# =====================================================================
# ---- MARKER: NOISE REMOVAL (runs on the black/white page, BEFORE line finding) ----
# Only whole separate ink pieces are deleted; the letters' strokes are
# never blurred, thickened or thinned, so the HOG shape the model was
# trained on stays exactly the same (no retraining needed).
# Every size is measured against YOUR writing: L = typical letter height,
# t = pen stroke thickness - so it works for small and big handwriting.
NOISE_MIN_PIECES_FOR_STATS = 3      # need at least 3 letter-sized pieces to judge
NOISE_SMALL_FRAC = 0.35             # piece < 35% of L (both sides) = "small"
NOISE_KUDLIT_REACH_FRAC = 0.6       # small piece within 0.6 L above/below a letter = kudlit, keep
NOISE_KUDLIT_SIDE_FRAC = 0.1        # ... and horizontally within 0.1 L of that letter
NOISE_KUDLIT_OWNER_MAX_FRAC = 3.0  # a kudlit's letter may be up to 3 L wide (Nga is wide)
NOISE_MIN_MARK_AREA_STROKES = 0.5   # ink area < 0.5 x stroke^2 = too tiny even for a pen dot
NOISE_LINE_LONG_FRAC = 3.0          # longer than 3 L ...
NOISE_LINE_THIN_FRAC = 0.5          # ... and thinner than 0.5 L = notebook / margin line
NOISE_EDGE_BIG_FRAC = 2.0           # touches photo border and > 2 L = shadow / table / paper edge
NOISE_BLOB_SIZE_FRAC = 2.5          # both sides > 2.5 L ...
NOISE_BLOB_INK_FRAC = 1.5           # ... and ink area > 1.5 L^2 = finger / stain / solid blob


def remove_noise(binary_img, debug=False):
    """
    Deletes ink pieces that cannot be writing:
      1. small specks (dust, paper grain, pen skips) - EXCEPT small marks
         right above/below a letter, which are kudlit dots/crosses
      2. long thin lines (notebook rules, margin line)
      3. big pieces touching the photo border (shadow, table, paper edge)
      4. huge solid blobs (finger, stain)
    Returns the cleaned binary image.
    """
    num, labels, stats, _ = cv2.connectedComponentsWithStats(binary_img, connectivity=8)
    if num <= 1:
        return binary_img

    img_h, img_w = binary_img.shape[:2]
    stroke = _estimate_stroke_thickness(binary_img)

    xs = stats[1:, cv2.CC_STAT_LEFT]
    ys = stats[1:, cv2.CC_STAT_TOP]
    ws = stats[1:, cv2.CC_STAT_WIDTH]
    hs = stats[1:, cv2.CC_STAT_HEIGHT]
    areas = stats[1:, cv2.CC_STAT_AREA]

    # Typical letter height L: pieces clearly bigger than a pen dot and
    # not page-sized (lines / edges would push the estimate up)
    letter_like = (np.maximum(ws, hs) >= 4 * stroke) & (np.maximum(ws, hs) < 0.5 * max(img_w, img_h))
    if int(letter_like.sum()) < NOISE_MIN_PIECES_FOR_STATS:
        if debug:
            print("  [marker debug] noise filter skipped: not enough letter-sized pieces")
        return binary_img
    letter_h = float(np.median(hs[letter_like]))
    if letter_h < 3:
        return binary_img

    small = (ws < NOISE_SMALL_FRAC * letter_h) & (hs < NOISE_SMALL_FRAC * letter_h)
    big = ~small
    remove = np.zeros(num - 1, dtype=bool)
    reasons = {}

    # Rules 2-4 first: big pieces that are lines / border junk / blobs
    for i in np.where(big)[0]:
        w, h, a = ws[i], hs[i], areas[i]
        touches_border = xs[i] <= 0 or ys[i] <= 0 or xs[i] + w >= img_w or ys[i] + h >= img_h
        if (w > NOISE_LINE_LONG_FRAC * letter_h and h < NOISE_LINE_THIN_FRAC * letter_h) or \
           (h > NOISE_LINE_LONG_FRAC * letter_h and w < NOISE_LINE_THIN_FRAC * letter_h):
            reason = 'line'          # 2. notebook / margin line
        elif touches_border and max(w, h) > NOISE_EDGE_BIG_FRAC * letter_h:
            reason = 'border junk'   # 3. shadow / table / paper edge
        elif (w > NOISE_BLOB_SIZE_FRAC * letter_h and h > NOISE_BLOB_SIZE_FRAC * letter_h
              and a > NOISE_BLOB_INK_FRAC * letter_h * letter_h):
            reason = 'blob'          # 4. finger / stain
        else:
            continue
        remove[i] = True
        reasons[reason] = reasons.get(reason, 0) + 1

    # Rule 1: small pieces. Real letters left after rules 2-4 are the
    # only things a kudlit can belong to (not a notebook line / edge).
    # (wide letters such as Nga can be ~2x as wide as they are tall, so the
    #  owner of a kudlit may be up to NOISE_KUDLIT_OWNER_MAX_FRAC x L wide)
    letters = np.where(big & ~remove & (np.maximum(ws, hs) <= NOISE_KUDLIT_OWNER_MAX_FRAC * letter_h))[0]
    reach = NOISE_KUDLIT_REACH_FRAC * letter_h
    side = NOISE_KUDLIT_SIDE_FRAC * letter_h
    min_mark_area = NOISE_MIN_MARK_AREA_STROKES * stroke * stroke
    bx0, by0 = xs[letters], ys[letters]
    bx1, by1 = bx0 + ws[letters], by0 + hs[letters]
    for i in np.where(small)[0]:
        if areas[i] < min_mark_area:
            # smaller than any dot a pen can make = dust / grain
            remove[i] = True
            reasons['speck'] = reasons.get('speck', 0) + 1
            continue
        # keep it only if a letter is right above/below it (kudlit)
        cx0, cy0 = xs[i], ys[i]
        cx1, cy1 = cx0 + ws[i], cy0 + hs[i]
        center_x = (cx0 + cx1) / 2.0  # a kudlit sits above/below a letter, not beside it
        horizontally_over = (center_x >= bx0 - side) & (center_x <= bx1 + side)
        vertical_gap = np.maximum(np.maximum(by0 - cy1, cy0 - by1), 0)
        if not np.any(horizontally_over & (vertical_gap <= reach)):
            remove[i] = True
            reasons['speck'] = reasons.get('speck', 0) + 1

    if debug:
        print(f"  [marker debug] noise filter: letter_height={letter_h:.1f}px, "
              f"stroke={stroke:.1f}px, removed={int(remove.sum())} piece(s) {reasons}")
    if not remove.any():
        return binary_img

    keep_lut = np.ones(num, dtype=bool)
    keep_lut[1:] = ~remove
    cleaned = np.where(keep_lut[labels], binary_img, 0).astype(binary_img.dtype)
    return cleaned


# ---- "WRITTEN ON PAPER?" CHECK ----
# Pen / marker letters sit on plain paper: after the lighting correction
# the paper around a letter is almost perfectly flat (spread ~0), and the
# ink is much darker. A wall, table, cloth or floor pattern that got
# binarized has a BUSY background instead. The ratio below is the
# background's spread divided by how much darker the ink is:
#   handwriting on paper ~0.00, textures/patterns ~0.07 - 0.7
TEXTURE_RATIO_MAX = 0.06
# whole photo rejected when at least this share of the glyph candidates
# sit on a textured background (see the page check in preprocess_and_predict)
PAGE_TEXTURE_REJECT_FRAC = 0.35
# whole photo rejected when fewer than half of the glyph candidates are
# kept as letters (a photo of a room, furniture or a screen)
PAGE_KEEP_MIN_FRAC = 0.5
PAGE_KEEP_MIN_CANDIDATES = 8
# ... or when a smaller share (>= 20%) is on texture AND the "letters" that
# are left have very uneven heights (door/chair/furniture edges). Real
# writing: texture share <= 9% and height spread <= 0.46 in our tests.
PAGE_TEXTURE_SOFT_FRAC = 0.20
PAGE_HEIGHT_SPREAD_MAX = 0.75


def background_texture_ratio(gray_rot, all_ink_rot, glyph_mask, x0, y0, pad):
    """Spread of the paper right around a glyph / how much darker its ink is."""
    h, w = glyph_mask.shape[:2]
    H, W = gray_rot.shape[:2]
    ink = gray_rot[y0:y0 + h, x0:x0 + w][glyph_mask > 0]
    ex0, ey0 = max(0, x0 - pad), max(0, y0 - pad)
    ex1, ey1 = min(W, x0 + w + pad), min(H, y0 + h + pad)
    around = gray_rot[ey0:ey1, ex0:ex1][all_ink_rot[ey0:ey1, ex0:ex1] == 0]
    if ink.size == 0 or around.size < 10:
        return 0.0
    contrast = float(np.median(around)) - float(np.median(ink))
    if contrast <= 1.0:
        return float('inf')
    q75, q25 = np.percentile(around, [75, 25])
    spread = (float(q75) - float(q25)) / 1.349   # robust std (ignores thin lines)
    return spread / contrast



# ---- "ON THE PAPER?" COLOUR CHECK ----
# A textured table / mat / cloth at the edge of the photo can pass the
# check above when the pattern is dense (almost everything around it turns
# black, so its "background" looks flat). The surface is still a different
# COLOUR from the paper: paper is near-gray (white, or gray in a shadow),
# a wooden table or woven mat is brown/coloured. So for each glyph the
# saturation (colourfulness) of the area around it is compared with the
# paper's: much more colourful = the glyph is on the surface, not the paper.
# Shadows on the paper stay gray, so letters in shadows are kept.
OFF_PAPER_SAT_DIFF = 40        # 0-255 scale; paper ~0-40, brown mat ~90-150
OFF_PAPER_WORK_SIDE = 800      # colour is checked on a small copy (fast)
OFF_PAPER_MIN_VALUE = 50       # ignore very dark pixels (their colour is noise)


class _PaperColour:
    def __init__(self, image_bytes, work_w, work_h):
        pil = PILImage.open(io.BytesIO(image_bytes))
        pil = ImageOps.exif_transpose(pil).convert('RGB')
        pil.thumbnail((OFF_PAPER_WORK_SIDE, OFF_PAPER_WORK_SIDE))
        hsv = np.array(pil.convert('HSV'))
        self.sat = hsv[..., 1]
        self.val = hsv[..., 2]
        self.fx = self.sat.shape[1] / float(max(1, work_w))
        self.fy = self.sat.shape[0] / float(max(1, work_h))
        bright = self.val >= 0.85 * float(np.percentile(self.val, 90))
        self.paper_sat = float(np.median(self.sat[bright])) if bright.any() else 0.0

    @classmethod
    def from_bytes(cls, image_bytes, work_w, work_h):
        try:
            return cls(image_bytes, work_w, work_h)
        except Exception:
            return None          # never let this check break recognition

    def saturation_above_paper(self, box, pad):
        """How much more colourful the area of box (x0, y0, x1, y1, in the
        working image) plus a margin is than the paper. 0 = same as paper."""
        x0, y0, x1, y1 = box
        H, W = self.sat.shape[:2]
        ix0, iy0 = int(x0 * self.fx), int(y0 * self.fy)
        ix1, iy1 = int(np.ceil(x1 * self.fx)), int(np.ceil(y1 * self.fy))
        p = max(2, int(round(pad * self.fx)))
        ex0, ey0 = max(0, ix0 - p), max(0, iy0 - p)
        ex1, ey1 = min(W, ix1 + p), min(H, iy1 + p)
        if ex1 <= ex0 or ey1 <= ey0:
            return 0.0
        # the glyph's own box AND the margin around it: a piece of a mat
        # strip can be as wide as the strip itself, so the margin alone
        # may be mostly paper. Ink is only a small part of a letter's box,
        # so the median is the colour of what the letter is written on.
        sat = self.sat[ey0:ey1, ex0:ex1]
        keep = self.val[ey0:ey1, ex0:ex1] >= OFF_PAPER_MIN_VALUE
        area = sat[keep]
        if area.size < 10:
            return 0.0
        return float(np.median(area)) - self.paper_sat




# ---- Marks that cannot be letters (noise in the photo) ----
# Before recognition, a mark is thrown away if its SHAPE cannot be one of
# the 19 handwritten letters (the SVM would otherwise force it into a
# letter, e.g. a crack or a table edge read as 't' 99%):
#   'line' - ONE straight stroke tilted more than 35 deg from vertical
#            (cracks, edges, underlines). l and i are straight too, but
#            close to vertical, so they are kept.
#   'blob' - a big mark that is almost all ink (objects, shadows). Thin
#            letters like l or i fill their narrow box too, so a blob must
#            also be wide AND tall.
STRAY_MIN_TILT_DEG = 35.0      # a straight stroke tilted more than this from vertical
STRAY_MAX_THICKNESS = 0.18     # "straight": width across the stroke / its length
STRAY_MIN_LENGTH = 4.0         # x stroke thickness
BLOB_MIN_FILL = 0.80
BLOB_MIN_SIDE = 3.0            # x stroke thickness, both sides

def shape_reason(glyph, stroke):
    """None if the mark could be a letter, else why it cannot."""
    ys, xs = np.nonzero(glyph)
    if len(xs) < 10:
        return None
    h, w = glyph.shape
    fill = len(xs) / float(h * w)
    if fill >= BLOB_MIN_FILL and min(h, w) >= BLOB_MIN_SIDE * stroke:
        return 'blob'
    pts = np.stack([xs, ys], 1).astype(np.float64)
    pts -= pts.mean(0)
    vals, vecs = np.linalg.eigh(np.cov(pts.T))
    l2, l1 = max(vals[0], 0.0), max(vals[1], 1e-9)
    vx, vy = vecs[:, 1]
    length = 4.0 * np.sqrt(l1)                       # ~ length of a straight line
    straight = np.sqrt(l2 / l1) <= STRAY_MAX_THICKNESS
    tilt = np.degrees(np.arctan2(abs(vx), abs(vy)))  # 0 = vertical, 90 = horizontal
    if straight and tilt > STRAY_MIN_TILT_DEG and length >= STRAY_MIN_LENGTH * stroke:
        return 'line'
    return None


def drop_non_letter_marks(line_bin, boxes):
    """Returns (kept boxes, number of marks thrown away)."""
    stroke = _estimate_stroke_thickness(line_bin)
    kept = [b for b in boxes if shape_reason(line_bin[b[1]:b[3], b[0]:b[2]], stroke) is None]
    return kept, len(boxes) - len(kept)


def estimate_latin_merge_kernel(bin_img):
    width, height = estimate_segment_merge_kernel(bin_img)
    return (min(width, LATIN_MERGE_MAX_WIDTH), height)


# ---- Recognition-based splitting (segmentation by recognition) ----
# A box that may hold 2+ TOUCHING letters is cut at every column where the
# ink is thin (candidate cut points). Every way of cutting it into pieces
# is scored by the Latin SVM (sum of log-probabilities of each piece's
# best letter), and the best-scoring set of pieces wins. Keeping the box
# whole is one of the options, so a wide single letter (m, w) is not cut
# when the SVM is more confident about it as one letter.
RECOG_SPLIT_MIN_WIDTH = 1.15     # x median letter height: only wider boxes are tried
RECOG_PIECE_MIN_WIDTH = 0.10     # x median height: thinnest allowed piece (l, i)
RECOG_PIECE_MAX_WIDTH = 1.7      # x median height: widest allowed piece (m, w)
RECOG_KEEP_CONFIDENCE = 0.60     # a normal-width box this sure of one letter is kept whole
RECOG_MAX_CUTS = 14              # most candidate cuts kept per box (speed)
RECOG_THIN_INK_FACTOR = 2.5      # a cut column has <= this x stroke thickness of ink


def _tight(mask):
    ys, xs = np.where(mask > 0)
    if len(xs) == 0:
        return None
    return mask[ys.min():ys.max() + 1, xs.min():xs.max() + 1], (int(xs.min()), int(ys.min()),
                                                               int(xs.max()) + 1, int(ys.max()) + 1)


def candidate_cuts(glyph, median_h, max_cuts=RECOG_MAX_CUTS):
    """Possible cut columns inside the box, best first:
      1. columns where the ink is thin (two letters joined by a thin stroke)
      2. other local minima of the ink profile (letters pressed together)
      3. if still nothing, evenly spaced columns about one letter apart
    The SVM later decides which of these cuts are real."""
    w = glyph.shape[1]
    col = (glyph > 0).sum(axis=0).astype(np.float64)
    if w < 5:
        return []
    smooth = np.convolve(col, np.ones(3) / 3.0, mode='same')
    thick = max(1.0, _estimate_stroke_thickness(glyph))
    limit = RECOG_THIN_INK_FACTOR * thick
    min_gap = max(2, int(RECOG_PIECE_MIN_WIDTH * median_h))

    minima = [x for x in range(min_gap, w - min_gap)
              if smooth[x] <= smooth[x - 1] and smooth[x] <= smooth[x + 1]]
    thin = sorted((col[x], x) for x in minima if col[x] <= limit)
    other = sorted((smooth[x], x) for x in minima if col[x] > limit)
    chosen = []
    for _, x in thin + other:
        if all(abs(x - c) >= min_gap for c in chosen):
            chosen.append(x)
        if len(chosen) >= max_cuts:
            break
    if not chosen and w > RECOG_PIECE_MAX_WIDTH * median_h:
        step = max(min_gap, int(0.6 * median_h))
        chosen = list(range(step, w - min_gap, step))[:max_cuts]
    return sorted(chosen)


def split_by_recognition(glyph, median_h, model, classes, force_split=False):
    """glyph: binary crop of ONE box. Returns a list of (x0, x1) column
    ranges (box coords), the best way to cut it into letters.

    Score of a cut = sum of log-probabilities of each piece's best letter.
    That sum naturally prefers FEWER pieces, so a confident single letter
    (m, w) is never cut. But when the box as ONE letter is weak (e.g. 's'
    and 'i' pressed together), the best 2+ piece reading is also tried and
    used if its pieces are, on average, more confident than the whole."""
    w = glyph.shape[1]
    cuts = [0] + candidate_cuts(glyph, median_h) + [w]
    if len(cuts) == 2:
        return [(0, w)]
    min_w = RECOG_PIECE_MIN_WIDTH * median_h
    max_w = RECOG_PIECE_MAX_WIDTH * median_h
    n = len(cuts)

    # Score ALL possible pieces in ONE SVM call (much faster on the phone
    # than one call per piece).
    pairs, crops = [], []
    for i in range(n):
        for j in range(i + 1, n):
            width = cuts[j] - cuts[i]
            whole = (i == 0 and j == n - 1)
            if width < min_w or (width > max_w and not whole):
                continue
            sub = glyph[:, cuts[i]:cuts[j]]
            t = _tight(sub)
            if t is None or cv2.countNonZero(sub) < 8:
                continue
            pairs.append((i, j))
            crops.append(t[0])
    cache = dict.fromkeys(((i, j) for i in range(n) for j in range(i + 1, n)))
    if crops:
        best_probs = [c[0][1] for c in classify_latin_batch(crops, model, classes)]
        cache.update(zip(pairs, best_probs))

    def piece_prob(a, b):
        return cache.get((a, b))

    def best_path(allow_whole):
        best = [-np.inf] * n
        back = [-1] * n
        best[0] = 0.0
        for j in range(1, n):
            for i in range(j - 1, -1, -1):
                if i == 0 and j == n - 1 and not allow_whole:
                    continue
                width = cuts[j] - cuts[i]
                if width > max_w and not (i == 0 and j == n - 1):
                    break
                if width < min_w or best[i] == -np.inf:
                    continue
                p = piece_prob(i, j)
                if p is None:
                    continue
                sc = best[i] + float(np.log(max(p, 1e-6)))
                if sc > best[j]:
                    best[j], back[j] = sc, i
        if best[-1] == -np.inf:
            return None
        path, j = [], n - 1
        while j > 0:
            i = back[j]
            path.append((i, j))
            j = i
        return path[::-1]

    if force_split:
        forced = best_path(allow_whole=False)
        return [(cuts[i], cuts[j]) for i, j in forced] if forced else [(0, w)]
    path = best_path(allow_whole=True)
    if path is None:
        return [(0, w)]
    if len(path) == 1:
        whole_p = piece_prob(0, n - 1) or 0.0
        if whole_p < RECOG_KEEP_CONFIDENCE:
            forced = best_path(allow_whole=False)
            if forced:
                probs = [piece_prob(i, j) or 0.0 for i, j in forced]
                if min(probs) >= NOISE_CONFIDENCE_THRESHOLD and np.mean(probs) > whole_p:
                    path = forced
    return [(cuts[i], cuts[j]) for i, j in path]


def refine_boxes_by_recognition(line_bin, boxes, model, classes):
    """Runs split_by_recognition on every box wide enough to hold 2+
    letters. Boxes in line coordinates (x0, y0, x1, y1)."""
    if not boxes:
        return []
    median_h = float(np.median([b[3] - b[1] for b in boxes]))
    out = []
    for (x0, y0, x1, y1) in boxes:
        glyph = line_bin[y0:y1, x0:x1]
        w = x1 - x0
        if median_h <= 0 or w < 2 * RECOG_PIECE_MIN_WIDTH * median_h:
            out.append((x0, y0, x1, y1))
            continue
        if w <= RECOG_SPLIT_MIN_WIDTH * median_h:
            # Normal letter width: keep it whole if the SVM is sure about it.
            # A narrow pair like 'ki' or 'si' pressed together gets a LOW
            # score as one letter, so it is still tried as a split.
            t = _tight(glyph)
            if t is None:
                continue
            if classify_latin_glyph(t[0], model, classes)[0][1] >= RECOG_KEEP_CONFIDENCE:
                out.append((x0, y0, x1, y1))
                continue
        for a, b in split_by_recognition(glyph, median_h, model, classes):
            t = _tight(glyph[:, a:b])
            if t is None:
                continue
            tx0, ty0, tx1, ty1 = t[1]
            out.append((x0 + a + tx0, y0 + ty0, x0 + a + tx1, y0 + ty1))
    return sorted(out, key=lambda b: b[0])


# ---- Recognition-based MERGING (letters written in 2+ separate strokes) ----
# Some people lift the pen inside one letter: 'k' = '|' + '<', 'a' = 'o' +
# '|'. Segmentation then gives 2 boxes for 1 letter (k -> "l p", a -> "o i").
# Inside each word, neighbouring boxes that are very close are also tried
# TOGETHER as one letter; the SVM decides (same log-probability scoring as
# the splitting, plus a margin). Two clear letters always stay apart.
MERGE_MAX_GAP = 0.15      # x median letter height: only boxes this close are tried together
MERGE_MAX_PIECES = 3      # at most 3 strokes are joined into one letter
# Joining pieces must beat keeping them apart by this much (log-probability).
# Without it, two CLEAR letters whose combined shape looks like another
# letter get joined (r+a -> m, k+a -> h, a+n -> m). A real broken letter
# (k read as 'l' 91% + 'p' 54%) gains far more than this when joined.
MERGE_MARGIN = 0.15


def merge_by_recognition(mask, boxes, median_h, model, classes):
    """boxes: one word's boxes (absolute coords), left to right.
    Returns [(box, candidates), ...] - the best grouping, already classified."""
    if not boxes:
        return []
    boxes = sorted(boxes, key=lambda b: b[0])
    n = len(boxes)
    max_w = RECOG_PIECE_MAX_WIDTH * median_h
    max_gap = MERGE_MAX_GAP * median_h

    def union(i, j):
        bs = boxes[i:j]
        return (min(b[0] for b in bs), min(b[1] for b in bs),
                max(b[2] for b in bs), max(b[3] for b in bs))

    # every allowed group of consecutive boxes, classified in ONE SVM call
    groups, crops = [], []
    for i in range(n):
        for j in range(i + 1, min(n, i + MERGE_MAX_PIECES) + 1):
            if j - i > 1:
                gaps = [boxes[k + 1][0] - boxes[k][2] for k in range(i, j - 1)]
                u = union(i, j)
                if max(gaps) > max_gap or (u[2] - u[0]) > max_w:
                    break
            u = union(i, j)
            glyph = mask[u[1]:u[3], u[0]:u[2]]
            if cv2.countNonZero(glyph) == 0:
                continue
            groups.append((i, j, u))
            crops.append(glyph)
    if not crops:
        return []
    cands = dict(zip([(i, j) for i, j, _ in groups],
                     zip([u for _, _, u in groups],
                         classify_latin_batch(crops, model, classes))))

    best = [-np.inf] * (n + 1)
    back = [-1] * (n + 1)
    best[0] = 0.0
    for j in range(1, n + 1):
        for i in range(max(0, j - MERGE_MAX_PIECES), j):
            if (i, j) not in cands or best[i] == -np.inf:
                continue
            sc = best[i] + float(np.log(max(cands[(i, j)][1][0][1], 1e-6)))
            if j - i > 1:
                sc -= MERGE_MARGIN
            if sc > best[j]:
                best[j], back[j] = sc, i
    if best[n] == -np.inf:
        return [(cands[(k, k + 1)][0], cands[(k, k + 1)][1])
                for k in range(n) if (k, k + 1) in cands]
    out, j = [], n
    while j > 0:
        i = back[j]
        out.append(cands[(i, j)])
        j = i
    return out[::-1]


# ---- Reading a WORD: try several cuttings, let the dictionary choose ----
# Touching letters can look like ONE other letter to the SVM, with high
# confidence (r+a -> 'm' 99%, k+a -> 'h'), and a letter written in two
# strokes can look like TWO letters (a -> 'o' + 'i'). Confidence alone
# cannot tell these apart, but the word can: "paamioin" is not a Filipino
# word, "paaralan" is. So every box of a word may be:
#   - kept whole,
#   - split into its best 2-3 letters (if it is wide enough), or
#   - joined with its close neighbours (pen lifted inside one letter),
# and the reading that forms a real word wins. With no dictionary match,
# the most confident reading is used (joining / splitting must beat
# keeping whole by a margin, so clear letters are never changed).
SPLIT_MIN_WIDTH = 0.85        # x median height: narrower boxes are never split
SPLIT_MARGIN = 0.15           # like MERGE_MARGIN, for splitting one box into letters
SPLIT_ONLY_BELOW = 0.90       # a normal-width letter read at least this sure is not cut (speed)
MAX_READINGS = 256            # most cuttings tried per word


def _box_union(bs):
    return (min(b[0] for b in bs), min(b[1] for b in bs),
            max(b[2] for b in bs), max(b[3] for b in bs))


def read_word(mask, boxes, median_h, model, classes, word_set=None):
    """boxes: one word's boxes (absolute coords).
    Returns (pieces, word, status) where pieces = [(box, candidates), ...]."""
    boxes = sorted(boxes, key=lambda b: b[0])
    n = len(boxes)
    if n == 0:
        return [], '', 'model'
    max_w = RECOG_PIECE_MAX_WIDTH * median_h
    max_gap = MERGE_MAX_GAP * median_h

    # ---- 0. read every box whole first (ONE SVM call) - speed: a letter of
    # normal width that the SVM is already sure about is never cut, so the
    # slow "try every cut" step only runs where it can help ----
    whole_ok = [cv2.countNonZero(mask[b[1]:b[3], b[0]:b[2]]) > 0 for b in boxes]
    whole_list = [b for b, ok in zip(boxes, whole_ok) if ok]
    whole_cands = dict(zip(whole_list, classify_latin_batch(
        [mask[b[1]:b[3], b[0]:b[2]] for b in whole_list], model, classes))) if whole_list else {}

    def worth_splitting(b):
        w = b[2] - b[0]
        if w < SPLIT_MIN_WIDTH * median_h:
            return False                          # too narrow for 2 letters
        if w >= RECOG_SPLIT_MIN_WIDTH * median_h:
            return True                           # wide: may hold 2 touching letters
        c = whole_cands.get(b)
        return c is None or c[0][1] < SPLIT_ONLY_BELOW   # normal width: only if unsure

    # ---- 1. every possible piece of the word (an "edge" from box i to box j) ----
    edges = {}           # i -> list of (j, [box,...], penalty)
    for i in range(n):
        b = boxes[i]
        edges.setdefault(i, []).append((i + 1, [b], 0.0))                  # keep whole
        if worth_splitting(b):                                            # split
            glyph = mask[b[1]:b[3], b[0]:b[2]]
            ranges = split_by_recognition(glyph, median_h, model, classes, force_split=True)
            if len(ranges) > 1:
                parts = []
                for a, c in ranges:
                    t = _tight(glyph[:, a:c])
                    if t is not None:
                        tx0, ty0, tx1, ty1 = t[1]
                        parts.append((b[0] + a + tx0, b[1] + ty0, b[0] + a + tx1, b[1] + ty1))
                if len(parts) > 1:
                    edges[i].append((i + 1, parts, SPLIT_MARGIN))
        for j in range(i + 2, min(n, i + MERGE_MAX_PIECES) + 1):          # join
            gaps = [boxes[k + 1][0] - boxes[k][2] for k in range(i, j - 1)]
            u = _box_union(boxes[i:j])
            if max(gaps) > max_gap or (u[2] - u[0]) > max_w:
                break
            edges[i].append((j, [u], MERGE_MARGIN))

    # ---- 2. classify every distinct piece in ONE SVM call ----
    # (the whole boxes were already read in step 0 - only the new pieces are)
    all_boxes = sorted({bx for lst in edges.values() for _, bxs, _ in lst for bx in bxs}
                       - set(whole_cands))
    crops = [mask[bx[1]:bx[3], bx[0]:bx[2]] for bx in all_boxes]
    keep = [k for k, c in enumerate(crops) if cv2.countNonZero(c) > 0]
    cands = dict(whole_cands)
    if keep:
        cands.update(zip([all_boxes[k] for k in keep],
                         classify_latin_batch([crops[k] for k in keep], model, classes)))

    # ---- 3. every reading (path through the word), best first ----
    readings = []

    def walk(i, pieces, score):
        if len(readings) >= MAX_READINGS:
            return
        if i == n:
            readings.append((score, list(pieces)))
            return
        for j, bxs, penalty in edges.get(i, []):
            if any(bx not in cands for bx in bxs):
                continue
            add = sum(float(np.log(max(cands[bx][0][1], 1e-6))) for bx in bxs) - penalty
            walk(j, pieces + [(bx, cands[bx]) for bx in bxs], score + add)

    walk(0, [], 0.0)
    if not readings:
        return [], '', 'model'
    readings.sort(key=lambda r: r[0], reverse=True)

    # ---- 4. the dictionary picks the first reading that is a real word ----
    if word_set:
        for score, pieces in readings:
            word, status = resolve_word([c for _, c in pieces], word_set)
            if (status in ('model', 'dictionary') and word in word_set
                    and (len(word) > 1 or word == 'o')):
                return pieces, word, ('model' if pieces is readings[0][1] and status == 'model'
                                      else 'dictionary')
    best = readings[0][1]
    word, status = resolve_word([c for _, c in best], word_set)
    return best, word, status


# ---- Word grouping for Latin ----
# Same 1D Otsu gap split as the Baybayin side, plus a floor: a gap only
# counts as a word space if it is at least this fraction of the median
# letter height. Without the floor, a line holding ONE word (no real word
# gap) would still be split wherever its letter gaps happen to differ.
WORD_GAP_MIN_FRAC = 0.45


def group_latin_words(boxes, min_frac=WORD_GAP_MIN_FRAC):
    if not boxes:
        return []
    row = sorted(boxes, key=lambda b: b[0])
    if len(row) == 1:
        return [row]
    median_h = float(np.median([b[3] - b[1] for b in row]))
    gaps = [row[i][0] - row[i - 1][2] for i in range(1, len(row))]
    word_gap = max(otsu_1d_threshold(gaps), min_frac * median_h)
    words, current = [], [row[0]]
    for i in range(1, len(row)):
        if gaps[i - 1] > word_gap:
            words.append(current)
            current = [row[i]]
        else:
            current.append(row[i])
    words.append(current)
    return words


# =====================================================================
# PHONE-SIDE HOG + SVM (NumPy only) - copied unchanged from the export
# script used for the Baybayin models, so both directions run the same code.
# =====================================================================
# ---- NumPy HOG (the same one the phone uses) ----
def _normalize_block_l2hys(block, eps=1e-5):
    out = block / np.sqrt(np.sum(block ** 2) + eps ** 2)
    out = np.minimum(out, 0.2)
    out = out / np.sqrt(np.sum(out ** 2) + eps ** 2)
    return out


def numpy_hog(image, orientations=9, pixels_per_cell=(8, 8), cells_per_block=(3, 3),
              block_norm='L2-Hys', visualize=False, transform_sqrt=False,
              feature_vector=True, **_unused):
    image = np.atleast_2d(np.asarray(image))
    dtype = np.float32 if image.dtype == np.float32 else np.float64
    image = image.astype(dtype, copy=False)
    if transform_sqrt:
        image = np.sqrt(image)
    g_row = np.zeros_like(image)
    g_col = np.zeros_like(image)
    g_row[1:-1, :] = image[2:, :] - image[:-2, :]
    g_col[:, 1:-1] = image[:, 2:] - image[:, :-2]
    s_row, s_col = image.shape
    c_row, c_col = pixels_per_cell
    b_row, b_col = cells_per_block
    n_cells_row = int(s_row // c_row)
    n_cells_col = int(s_col // c_col)
    g_row = g_row.astype(np.float64)
    g_col = g_col.astype(np.float64)
    magnitude = np.hypot(g_col, g_row)
    orientation = np.rad2deg(np.arctan2(g_row, g_col)) % 180
    bin_width = 180.0 / orientations
    histogram = np.zeros((n_cells_row, n_cells_col, orientations), dtype=np.float64)
    mag = magnitude[:n_cells_row * c_row, :n_cells_col * c_col]
    ori = orientation[:n_cells_row * c_row, :n_cells_col * c_col]
    for i in range(orientations):
        in_bin = (ori < bin_width * (i + 1)) & (ori >= bin_width * i)
        masked = np.where(in_bin, mag, 0.0)
        cell_sums = masked.reshape(n_cells_row, c_row, n_cells_col, c_col).sum(axis=(1, 3))
        histogram[:, :, i] = cell_sums / (c_row * c_col)
    n_blocks_row = (n_cells_row - b_row) + 1
    n_blocks_col = (n_cells_col - b_col) + 1
    # Speed: all blocks are normalized at once (same L2-Hys math as
    # _normalize_block_l2hys, applied to every block in one NumPy step).
    blocks = np.empty((n_blocks_row, n_blocks_col, b_row, b_col, orientations), dtype=np.float64)
    for i in range(b_row):
        for j in range(b_col):
            blocks[:, :, i, j, :] = histogram[i:i + n_blocks_row, j:j + n_blocks_col, :]
    eps = 1e-5
    norm = np.sqrt(np.sum(blocks ** 2, axis=(2, 3, 4), keepdims=True) + eps ** 2)
    blocks = np.minimum(blocks / norm, 0.2)
    norm = np.sqrt(np.sum(blocks ** 2, axis=(2, 3, 4), keepdims=True) + eps ** 2)
    blocks = (blocks / norm).astype(dtype, copy=False)
    return blocks.ravel() if feature_vector else blocks


# ---- NumPy SVM (the same one the phone uses) ----
class OfflineSVC:
    def __init__(self, npz_path):
        data = np.load(npz_path, allow_pickle=False)
        # float32: half the memory on the phone and a faster kernel
        self.support_vectors = data['support_vectors'].astype(np.float32)
        self.dual_coef = data['dual_coef'].astype(np.float64)
        self.intercept = data['intercept'].astype(np.float64)
        self.n_support = data['n_support'].astype(np.int64)
        self.prob_a = data['prob_a'].astype(np.float64)
        self.prob_b = data['prob_b'].astype(np.float64)
        self.gamma = float(data['gamma'])
        self.classes_ = data['classes']
        self.n_classes = len(self.n_support)
        self._starts = np.concatenate([[0], np.cumsum(self.n_support)[:-1]])
        self._sv_sq = np.sum(self.support_vectors.astype(np.float64) ** 2, axis=1)
        self._cache_key = None
        self._cache_value = None

    def _kernel(self, X):
        X = np.atleast_2d(np.asarray(X, dtype=np.float64))
        cross = (X.astype(np.float32) @ self.support_vectors.T).astype(np.float64)
        sq_dist = (np.sum(X ** 2, axis=1)[:, None] + self._sv_sq[None, :] - 2.0 * cross)
        np.maximum(sq_dist, 0, out=sq_dist)
        return np.exp(-self.gamma * sq_dist)

    def decision_ovo(self, X):
        X = np.atleast_2d(np.asarray(X, dtype=np.float64))
        key = (X.shape, X.tobytes())
        if key == self._cache_key:
            return self._cache_value
        K = self._kernel(X)
        k = self.n_classes
        out = np.zeros((X.shape[0], k * (k - 1) // 2))
        p = 0
        for i in range(k):
            si, ni = self._starts[i], self.n_support[i]
            for j in range(i + 1, k):
                sj, nj = self._starts[j], self.n_support[j]
                value = (K[:, si:si + ni] @ self.dual_coef[j - 1, si:si + ni]
                         + K[:, sj:sj + nj] @ self.dual_coef[i, sj:sj + nj])
                out[:, p] = value + self.intercept[p]
                p += 1
        self._cache_key, self._cache_value = key, out
        return out

    def predict(self, X):
        dec = self.decision_ovo(X)
        k = self.n_classes
        predictions = []
        for row in dec:
            votes = np.zeros(k, dtype=np.int64)
            p = 0
            for i in range(k):
                for j in range(i + 1, k):
                    if row[p] > 0:
                        votes[i] += 1
                    else:
                        votes[j] += 1
                    p += 1
            predictions.append(self.classes_[int(np.argmax(votes))])
        return np.array(predictions)

    @staticmethod
    def _sigmoid(f, a, b):
        fapb = f * a + b
        if fapb >= 0:
            return np.exp(-fapb) / (1.0 + np.exp(-fapb))
        return 1.0 / (1.0 + np.exp(fapb))

    @staticmethod
    def _multiclass_probability(k, r):
        p = np.full(k, 1.0 / k)
        Q = np.zeros((k, k))
        for t in range(k):
            for j in range(t):
                Q[t, t] += r[j, t] * r[j, t]
                Q[t, j] = Q[j, t]
            for j in range(t + 1, k):
                Q[t, t] += r[j, t] * r[j, t]
                Q[t, j] = -r[j, t] * r[t, j]
        eps = 0.005 / k
        Qp = np.zeros(k)
        for _ in range(max(100, k)):
            pQp = 0.0
            for t in range(k):
                Qp[t] = float(Q[t] @ p)
                pQp += p[t] * Qp[t]
            if np.max(np.abs(Qp - pQp)) < eps:
                break
            for t in range(k):
                diff = (-Qp[t] + pQp) / Q[t, t]
                p[t] += diff
                pQp = (pQp + diff * (diff * Q[t, t] + 2 * Qp[t])) / (1 + diff) / (1 + diff)
                Qp = (Qp + diff * Q[t]) / (1 + diff)
                p = p / (1 + diff)
        return p

    def predict_proba(self, X):
        dec = self.decision_ovo(X)
        k = self.n_classes
        result = np.zeros((dec.shape[0], k))
        for n, row in enumerate(dec):
            r = np.zeros((k, k))
            p = 0
            for i in range(k):
                for j in range(i + 1, k):
                    value = self._sigmoid(row[p], self.prob_a[p], self.prob_b[p])
                    value = min(max(value, 1e-7), 1 - 1e-7)
                    r[i, j] = value
                    r[j, i] = 1 - value
                    p += 1
            result[n] = [r[0, 1], r[1, 0]] if k == 2 else self._multiclass_probability(k, r)
        return result


# =====================================================================
# LATIN MODEL
# =====================================================================
_LATIN_MODEL = None
_LATIN_CLASSES = None
_WORD_SET = None

NOISE_CONFIDENCE_THRESHOLD = 0.30   # same as the Baybayin service

# ---------------------------------------------------------------------
# ERROR HANDLING: REJECT LETTERS THE MODEL NEVER LEARNED
# ---------------------------------------------------------------------
# The Latin SVM is closed-set: it ALWAYS answers with one of its 19
# letters, even for a C, a number or a Baybayin character. To avoid that,
# every letter also gets a "how familiar is this?" score:
#   sim5 / sim1 : RBF similarity to the closest support vectors
#                 (the same kernel the SVM uses), or
#   prob        : the SVM's top probability.
# Which score and its limit come from latin_reject.json, MEASURED in Colab
# (calibrate_latin_rejection.py) on your real letters and on c f j q v x z.
# A letter below the limit is REJECTED: shown as '?', never guessed.
# If most letters on the photo are rejected -> "No Latin letters found".
# Without latin_reject.json nothing changes. Any error here only skips
# the rejection - it can never stop a scan.
_REJECT_CFG = None
# DOUBLE CHECK used when there is no latin_reject.json: the model must be
# at least this sure that a mark is one of its 19 letters. Letters that are
# NOT in the model (C, F, J, Q, V, X, Z) get unsure answers (C -> e 34-69%,
# F -> p 34-86%, Z -> l 58%), while real letters are usually 95-100%.
# Only applied to words that are NOT real Filipino words (Tagalog_words.csv),
# so mahal, kung, pilipino... are never touched.
DEFAULT_SURE_LIMIT = 0.90
# Letters Baybayin cannot write. The 26-class Latin model can READ them,
# and every letter read as one of these is dropped (no box, no prediction).
UNSUPPORTED_LETTERS = set('cfjqvxz')
# The word list has junk short entries ('ee', 'ky', 'pp'...), so a word of 1-2
# letters only counts as real if it is a common Filipino short word.
TRUSTED_SHORT_WORDS = {
    'ay', 'at', 'sa', 'si', 'ni', 'na', 'ng', 'ko', 'mo', 'ka', 'ba', 'po',
    'di', 'ma', 'pa', 'ha', 'oo', 'o', 'e', 'ga', 'ito', 'yan',
}


def is_trusted_word(word, word_set):
    """A real Filipino word that the double check must never touch."""
    if not word_set or not word:
        return False
    if len(word) <= 2:
        return word in TRUSTED_SHORT_WORDS
    return word in word_set
PAGE_REJECT_FRACTION = 0.5     # this share of letters rejected -> no Latin on the photo
UNKNOWN_MARK = '?'
# What happens to a rejected letter:
#   'drop' - removed completely: no prediction, no bounding box
#            ("Filipino" with an unknown F -> "ilipino")
#   'mark' - kept as '?' so the user sees something was skipped ("?ilipino")
REJECT_MODE = 'drop'


def load_reject_config(path):
    """Reads latin_reject.json; returns None if it is missing or invalid."""
    global _REJECT_CFG
    try:
        with open(path, encoding='utf-8') as f:
            cfg = json.load(f)
        if cfg.get('score') in ('prob', 'sim1', 'sim5') and float(cfg['threshold']) >= 0:
            _REJECT_CFG = {'score': cfg['score'], 'threshold': float(cfg['threshold'])}
    except Exception:
        _REJECT_CFG = None
    return _REJECT_CFG


def familiarity_scores(glyph_masks, top_probs, model, score):
    """One score per letter (higher = more like a letter the model knows)."""
    if score == 'prob':
        return [float(p) for p in top_probs]
    feats = np.vstack([latin_features(g) for g in glyph_masks])
    k = model._kernel(feats)                          # same RBF kernel as the SVM
    top = -np.partition(-k, min(4, k.shape[1] - 1), axis=1)[:, :5]
    return [float(v) for v in (top.max(axis=1) if score == 'sim1' else top.mean(axis=1))]


def reject_unknown_letters(glyph_masks, top_probs, model, cfg=None):
    """[True/False] per letter: True = not a letter the model knows."""
    cfg = cfg if cfg is not None else _REJECT_CFG
    if not cfg or not glyph_masks:
        return [False] * len(glyph_masks)
    try:
        s = familiarity_scores(glyph_masks, top_probs, model, cfg['score'])
        return [v < cfg['threshold'] for v in s]
    except Exception:                                 # never stop a scan
        return [False] * len(glyph_masks)


def latin_word_to_baybayin_marked(word):
    """Like latin_word_to_baybayin, but a rejected letter ('?') stays '?'
    in the Baybayin instead of silently disappearing."""
    bay, sylls, chunk = [], [], ''
    for ch in word.lower():
        if ch == UNKNOWN_MARK:
            if chunk:
                b, s = latin_word_to_baybayin(chunk)
                bay.append(b); sylls.extend(s); chunk = ''
            bay.append(UNKNOWN_MARK)
            sylls.append((UNKNOWN_MARK, UNKNOWN_MARK))
        else:
            chunk += ch
    if chunk:
        b, s = latin_word_to_baybayin(chunk)
        bay.append(b); sylls.extend(s)
    return ''.join(bay), sylls
ALT_MIN_PROB = 0.15                 # a 2nd-best letter is only tried if >= 15%
MAX_AMBIGUOUS_LETTERS = 6           # at most 2^6 = 64 spellings tried per word


def load_latin_model(model_path='model_latin.npz', classes_path='latin_classes.json'):
    """Loads the exported Latin SVM (.npz, same format as model_base.npz)
    and its class names. A .pkl can still be passed for testing on a PC."""
    global _LATIN_MODEL, _LATIN_CLASSES
    if str(model_path).endswith('.npz'):
        _LATIN_MODEL = OfflineSVC(model_path)
    else:                                   # PC testing only (needs scikit-learn)
        import joblib
        _LATIN_MODEL = joblib.load(model_path)
    if str(classes_path).endswith('.json'):
        with open(classes_path, encoding='utf-8') as f:
            _LATIN_CLASSES = [str(c).lower() for c in json.load(f)['latin_classes']]
    else:
        import joblib
        _LATIN_CLASSES = [str(c).lower() for c in joblib.load(classes_path)['latin_classes']]
    return _LATIN_MODEL, _LATIN_CLASSES


def load_word_set(path):
    """Same Filipino word list used by the Baybayin side (one word per line)."""
    global _WORD_SET
    with open(path, encoding='utf-8') as f:
        _WORD_SET = {line.strip().lower() for line in f if line.strip()}
    return _WORD_SET


def latin_features(glyph_mask):
    """56x56 framing identical to training, then the same HOG as training."""
    norm = normalize_for_model(glyph_mask).astype(np.float32) / 255.0
    return numpy_hog(norm, orientations=9, pixels_per_cell=(8, 8),
                     cells_per_block=(2, 2), transform_sqrt=True,
                     visualize=False).reshape(1, -1)


def classify_latin_batch(glyph_masks, model, classes):
    """Same as classify_latin_glyph for many glyphs, with one SVM call."""
    feats = np.vstack([latin_features(g) for g in glyph_masks])
    probs = model.predict_proba(feats)
    out = []
    for row in probs:
        order = np.argsort(row)[::-1]
        out.append([(classes[int(model.classes_[i])], float(row[i])) for i in order[:3]])
    return out


def classify_latin_glyph(glyph_mask, model, classes):
    """Returns [(letter, prob), ...] best first."""
    feats = latin_features(glyph_mask)
    if hasattr(model, 'predict_proba'):
        probs = model.predict_proba(feats)[0]
        order = np.argsort(probs)[::-1]
        return [(classes[int(model.classes_[i])], float(probs[i])) for i in order[:3]]
    pred = model.predict(feats)[0]
    return [(classes[int(pred)], 1.0)]


# =====================================================================
# DICTIONARY CORRECTION (pure function - easy to unit test)
# =====================================================================
def resolve_word(letter_candidates, word_set=None,
                 alt_min_prob=ALT_MIN_PROB, max_ambiguous=MAX_AMBIGUOUS_LETTERS):
    """letter_candidates: one list per letter, [(letter, prob), ...] best first.

    Returns (word, status):
      'model'       - best guess kept (no word list, or already a real word)
      'dictionary'  - a 2nd-best spelling was a real word and was used
      'unresolved'  - not a real word, best guess kept
    """
    best = ''.join(c[0][0] for c in letter_candidates)
    if not word_set or best in word_set:
        return best, 'model'
    options, ambiguous = [], 0
    for cands in letter_candidates:
        opts = [cands[0]]
        if (len(cands) > 1 and cands[1][1] >= alt_min_prob
                and ambiguous < max_ambiguous):
            opts.append(cands[1])
            ambiguous += 1
        options.append(opts)
    best_word, best_score = None, -1.0
    for combo in product(*options):
        word = ''.join(c[0] for c in combo)
        if word in word_set:
            score = float(np.prod([c[1] for c in combo]))
            if score > best_score:
                best_word, best_score = word, score
    if best_word is not None:
        return best_word, 'dictionary'
    return best, 'unresolved'


# =====================================================================
# LATIN -> BAYBAYIN (pure function - easy to unit test)
# Tagalog Unicode block. B17+: d and r share DA (same as the Baybayin
# model's 'Da' class), so bahay <-> bahay and daan/raan agree.
# =====================================================================
VOWELS = set('aeiou')
CONSONANT_BASE = {
    'k': 'ᜃ', 'g': 'ᜄ', 'ng': 'ᜅ', 't': 'ᜆ',
    'd': 'ᜇ', 'r': 'ᜇ', 'n': 'ᜈ', 'p': 'ᜉ',
    'b': 'ᜊ', 'm': 'ᜋ', 'y': 'ᜌ', 'l': 'ᜎ',
    'w': 'ᜏ', 's': 'ᜐ', 'h': 'ᜑ',
}
STANDALONE_VOWEL = {'a': 'ᜀ', 'e': 'ᜁ', 'i': 'ᜁ',
                    'o': 'ᜂ', 'u': 'ᜂ'}
KUDLIT = {'a': '', 'e': 'ᜒ', 'i': 'ᜒ', 'o': 'ᜓ', 'u': 'ᜓ'}
KRUS_KUDLIT = '᜔'   # cancels the vowel: final / lone consonant

# 'mga' is written MA + NGA in Baybayin (the g has no letter of its own)
SPECIAL_WORDS = {'mga': [('ma', 'ᜋ'), ('nga', 'ᜅ')]}


def tokenize_latin(word):
    """'bahay' -> ['b','a','h','a','y'];  'ang' -> ['a','ng']"""
    tokens, i = [], 0
    while i < len(word):
        if word[i:i + 2] == 'ng':
            tokens.append('ng')
            i += 2
        else:
            tokens.append(word[i])
            i += 1
    return tokens


def latin_word_to_baybayin(word):
    """Returns (baybayin, syllables) where syllables = [(latin, baybayin), ...].

    Rules:
      consonant + vowel   -> one character (+ kudlit for e/i above, o/u below)
      consonant alone     -> consonant + krus-kudlit
      vowel alone         -> standalone vowel (A, E/I, O/U)
      letters outside the 19 classes are skipped
    """
    word = word.lower()
    if word in SPECIAL_WORDS:
        sylls = SPECIAL_WORDS[word]
        return ''.join(b for _, b in sylls), list(sylls)
    tokens = tokenize_latin(word)
    sylls, i = [], 0
    while i < len(tokens):
        t = tokens[i]
        nxt = tokens[i + 1] if i + 1 < len(tokens) else None
        if t in CONSONANT_BASE:
            if nxt in VOWELS:
                sylls.append((t + nxt, CONSONANT_BASE[t] + KUDLIT[nxt]))
                i += 2
            else:
                sylls.append((t, CONSONANT_BASE[t] + KRUS_KUDLIT))
                i += 1
        elif t in VOWELS:
            sylls.append((t, STANDALONE_VOWEL[t]))
            i += 1
        else:
            i += 1          # not a Filipino letter - skip
    return ''.join(b for _, b in sylls), sylls


def latin_text_to_baybayin(text):
    """Whole text, keeps spaces and line breaks.
    'ang bahay' -> 'ᜀᜅ᜔ ᜊᜑᜌ᜔'"""
    out_lines = []
    for line in text.lower().split('\n'):
        words = [latin_word_to_baybayin(w)[0] for w in re.findall(r'[a-z]+', line)]
        out_lines.append(' '.join(w for w in words if w))
    return '\n'.join(out_lines)


# =====================================================================
# MAIN ENTRY: photo -> Latin letters -> Baybayin
# =====================================================================
def preprocess_and_predict_latin(image_bytes, latin_model=None, latin_classes=None,
                                 word_set=None, debug=False):
    latin_model = latin_model or _LATIN_MODEL
    latin_classes = latin_classes or _LATIN_CLASSES
    word_set = word_set if word_set is not None else _WORD_SET
    if latin_model is None or latin_classes is None:
        raise ValueError('Latin model not loaded - call warm_up_latin() first')

    def result(status, message='', w=0, h=0, **extra):
        out = {'status': status, 'message': message, 'baybayin_text': '',
               'latin_text': '', 'confidence': 0.0, 'detections': [],
               'words': [], 'image_width': int(w), 'image_height': int(h)}
        out.update(extra)
        # same key the Baybayin side uses, so existing result widgets work
        out['translated_text'] = out['baybayin_text']
        return out

    try:
        image = decode_grayscale_exif_corrected(image_bytes)
    except Exception:
        return result('error', 'Could not read the image.')

    raw_h, raw_w = image.shape[:2]

    # ---- same blur check as the Baybayin side ----
    blur_score = compute_blur_score(image)
    if debug:
        print(f"  [latin debug] blur_score={blur_score:.2f}")
    if blur_score < BLUR_VARIANCE_THRESHOLD:
        return result('blurry', BLURRY_IMAGE_MESSAGE, raw_w, raw_h)

    # ---- same enhancement / normalization / Otsu / deskew ----
    raw_gray = image                                   # before enhancement
    image = enhance_image_quality(image)
    img_h, img_w = image.shape[:2]
    blur_size = min(101, max(15, (min(image.shape) // 3) | 1))
    background = cv2.GaussianBlur(image, (blur_size, blur_size), 0)
    normalized = cv2.divide(image, background, scale=255)
    binary = preprocess_image(normalized)

    skew_angle = estimate_skew_angle(binary)
    rot = cv2.getRotationMatrix2D((img_w / 2.0, img_h / 2.0), skew_angle, 1.0)
    rot_inv = cv2.invertAffineTransform(rot)
    binary = cv2.warpAffine(binary, rot, (img_w, img_h),
                            flags=cv2.INTER_NEAREST, borderValue=0)

    # ---- same "handwriting on paper?" checks as the Baybayin side ----
    # (each one is skipped if it fails - they can never stop a scan)
    binary_all_ink = binary                  # every dark mark, before cleaning
    try:
        binary = remove_noise(binary, debug=debug)   # specks, ruled lines, edges, blobs
    except Exception:
        binary = binary_all_ink
    paper_gray_rot, paper_colour = None, None
    try:
        # texture is measured on the plain (not sharpened) photo, exactly
        # like the Baybayin service where the limits were tuned
        g = raw_gray if raw_gray.shape[:2] == (img_h, img_w) else cv2.resize(
            raw_gray, (img_w, img_h), interpolation=cv2.INTER_CUBIC)
        g = cv2.divide(g, cv2.GaussianBlur(g, (blur_size, blur_size), 0), scale=255)
        paper_gray_rot = cv2.warpAffine(g, rot, (img_w, img_h),
                                        flags=cv2.INTER_LINEAR, borderValue=255)
        paper_colour = _PaperColour.from_bytes(image_bytes, img_w, img_h)
    except Exception:
        paper_gray_rot, paper_colour = None, None

    # Box coordinates are reported in the ENHANCED image's pixel space
    # (enhance_image_quality may upscale small photos), so scale back to
    # the original photo size for the app's box painter.
    sx, sy = raw_w / float(img_w), raw_h / float(img_h)

    line_bands = find_line_bands(binary)
    if debug:
        print(f"  [latin debug] skew={skew_angle:.1f}  lines={line_bands}")
    if not line_bands:
        return result('no_text', 'No letters detected.', raw_w, raw_h)
    line_masks = split_into_line_masks(binary, line_bands)

    detections, words_out, latin_lines, baybayin_lines = [], [], [], []
    letters_total, letters_rejected = 0, 0
    paper_candidates, texture_rejects = 0, 0
    kept_heights = []
    word_id = 0
    for full_mask in line_masks:
        rows = np.where(full_mask.any(axis=1))[0]
        if rows.size == 0:
            continue
        by0, by1 = int(rows.min()), int(rows.max()) + 1
        line_bin = full_mask[by0:by1, :]

        # one box per separate mark; the i-dot is joined to its own stem
        boxes = segment_latin_glyphs(line_bin)
        boxes = drop_orphan_fragments(boxes)            # drops specks / punctuation
        boxes = drop_too_tall_boxes(boxes)              # drops paper edges / shadows
        # cracks, lines and blobs can never be letters - throw them away
        boxes, n_noise = drop_non_letter_marks(line_bin, boxes)
        letters_total += n_noise
        letters_rejected += n_noise
        if not boxes:
            continue
        boxes = [(x0, y0 + by0, x1, y1 + by0) for (x0, y0, x1, y1) in boxes]

        # ---- "written on paper?" (texture) and "on the paper?" (colour) ----
        if paper_gray_rot is not None:
            line_h = float(np.median([b[3] - b[1] for b in boxes]))
            pad = max(4, int(0.3 * line_h))
            kept = []
            for (x0, y0, x1, y1) in boxes:
                paper_candidates += 1
                try:
                    texture = background_texture_ratio(
                        paper_gray_rot, binary_all_ink, full_mask[y0:y1, x0:x1], x0, y0, pad)
                    if texture > TEXTURE_RATIO_MAX:
                        texture_rejects += 1
                        continue
                    if paper_colour is not None and paper_colour.saturation_above_paper(
                            map_box_to_original(rot_inv, x0, y0, x1, y1), pad) > OFF_PAPER_SAT_DIFF:
                        continue
                except Exception:
                    pass
                kept.append((x0, y0, x1, y1))
            letters_total += len(boxes) - len(kept)
            letters_rejected += len(boxes) - len(kept)
            boxes = kept
            if not boxes:
                continue
        kept_heights += [b[3] - b[1] for b in boxes]

        line_latin, line_bayb = [], []
        line_median_h = float(np.median([b[3] - b[1] for b in boxes]))
        for word_boxes in group_latin_words(boxes):
            cands_per_letter, letter_dets, letter_glyphs = [], [], []
            # touching letters are split, broken letters are joined - the
            # reading that forms a real Filipino word wins
            pieces, latin_word, status = read_word(
                full_mask, word_boxes, line_median_h, latin_model, latin_classes, word_set)
            for (x0, y0, x1, y1), cands in pieces:
                glyph = full_mask[y0:y1, x0:x1]
                if cands[0][1] < NOISE_CONFIDENCE_THRESHOLD and status != 'dictionary':
                    # a mark the model cannot read at all also counts as
                    # "not a known letter" when deciding if the photo is Latin
                    letters_total += 1
                    letters_rejected += 1
                    if debug:
                        print(f"  [latin debug] dropped low-confidence glyph {cands[0]}")
                    continue
                ox0, oy0, ox1, oy1 = map_box_to_original(rot_inv, x0, y0, x1, y1)
                ok, buf = cv2.imencode('.png', normalize_for_model(glyph))
                cands_per_letter.append(cands)
                letter_glyphs.append(glyph)
                letter_dets.append({
                    'char': cands[0][0],
                    'confidence': round(cands[0][1] * 100, 2),
                    'alternatives': [{'char': c, 'confidence': round(p * 100, 2)}
                                     for c, p in cands[1:]],
                    'word_id': word_id,
                    'processed_image': base64.b64encode(buf.tobytes()).decode('ascii') if ok else None,
                    'bbox': {'x0': int(round(ox0 * sx)), 'y0': int(round(oy0 * sy)),
                             'x1': int(round(ox1 * sx)), 'y1': int(round(oy1 * sy))},
                })
            if not cands_per_letter:
                continue

            if len(cands_per_letter) != len(pieces):       # a noise speck was dropped
                latin_word, status = resolve_word(cands_per_letter, word_set)
            if debug and status != 'model':
                raw = ''.join(c[0][0] for c in cands_per_letter)
                print(f"  [latin debug] '{raw}' -> '{latin_word}' ({status})")
            # the dictionary may have changed some letters - show the final ones
            for det, ch in zip(letter_dets, latin_word):
                det['char'] = ch

            # ---- error handling: letters the model never learned -> '?' ----
            # (a real Filipino word is trusted as it is and never rejected)
            is_real = is_trusted_word(latin_word, word_set)
            rejected = [False] * len(letter_dets)
            if not is_real and len(latin_word) == len(letter_dets):
                rejected = reject_unknown_letters(
                    letter_glyphs, [c[0][1] for c in cands_per_letter], latin_model)
            # 26-class model: a letter READ as c f j q v x z is not in Baybayin
            # -> always dropped (with the 19-class model this never happens)
            if len(latin_word) == len(letter_dets):
                rejected = [r or ch in UNSUPPORTED_LETTERS
                            for r, ch in zip(rejected, latin_word)]
            letters_total += len(letter_dets)
            if any(rejected) and REJECT_MODE == 'drop':
                # unknown letters are removed: no prediction, no box
                letters_rejected += sum(1 for r in rejected if r)
                keep = [k for k, r in enumerate(rejected) if not r]
                letter_dets = [letter_dets[k] for k in keep]
                latin_word = ''.join(latin_word[k] for k in keep)
                if not letter_dets:              # the whole word was unknown
                    continue
                baybayin_word, sylls = latin_word_to_baybayin(latin_word)
            elif any(rejected):
                chars = list(latin_word)
                for k, (det, rej) in enumerate(zip(letter_dets, rejected)):
                    det['rejected'] = bool(rej)
                    if rej:
                        chars[k] = UNKNOWN_MARK
                        det['char'] = UNKNOWN_MARK
                        letters_rejected += 1
                latin_word = ''.join(chars)
                status = 'unknown_letters'
                baybayin_word, sylls = latin_word_to_baybayin_marked(latin_word)
            else:
                baybayin_word, sylls = latin_word_to_baybayin(latin_word)

            xs0 = [d['bbox']['x0'] for d in letter_dets]; ys0 = [d['bbox']['y0'] for d in letter_dets]
            xs1 = [d['bbox']['x1'] for d in letter_dets]; ys1 = [d['bbox']['y1'] for d in letter_dets]
            words_out.append({
                'word_id': word_id, 'latin': latin_word, 'baybayin': baybayin_word,
                'status': status,
                'syllables': [{'latin': l, 'baybayin': b} for l, b in sylls],
                'bbox': {'x0': min(xs0), 'y0': min(ys0), 'x1': max(xs1), 'y1': max(ys1)},
            })
            detections.extend(letter_dets)
            line_latin.append(latin_word)
            line_bayb.append(baybayin_word)
            word_id += 1

        if line_latin:
            latin_lines.append(' '.join(line_latin))
            baybayin_lines.append(' '.join(line_bayb))

    if not detections:
        return result('no_text', 'No letters detected.', raw_w, raw_h)
    # page check (same rule as the Baybayin side): many marks on a texture,
    # or some texture plus very uneven "letter" heights = not writing on paper
    texture_frac = texture_rejects / float(max(1, paper_candidates))
    height_spread = 0.0
    if kept_heights:
        hs = np.array(kept_heights, dtype=np.float64)
        height_spread = float((np.percentile(hs, 75) - np.percentile(hs, 25))
                              / max(1.0, float(np.median(hs))))
    if debug:
        print(f"  [latin debug] page: candidates={paper_candidates} texture={texture_frac:.0%} "
              f"spread={height_spread:.2f} rejected={letters_rejected}/{letters_total}")
    if (texture_frac >= PAGE_TEXTURE_REJECT_FRAC or
            (texture_frac >= PAGE_TEXTURE_SOFT_FRAC and height_spread > PAGE_HEIGHT_SPREAD_MAX)):
        return result('no_text', 'No Latin letters found.', raw_w, raw_h)
    # most marks on the photo are not letters the model knows (a Baybayin
    # photo, numbers, drawings...) -> say so instead of guessing
    if letters_total and letters_rejected / letters_total >= PAGE_REJECT_FRACTION:
        return result('no_text', 'No Latin letters found.', raw_w, raw_h)

    avg_conf = round(float(np.mean([d['confidence'] for d in detections])), 2)
    return result('ok', '', raw_w, raw_h,
                  baybayin_text='\n'.join(baybayin_lines),
                  latin_text='\n'.join(latin_lines),
                  confidence=avg_conf, detections=detections, words=words_out)


# Folder this file lives in (on the phone: the Chaquopy python folder,
# next to model_base.npz / model_dia.npz / model_latin.npz).
MODULE_DIR = os.path.dirname(os.path.abspath(__file__))


def _borrow_baybayin_word_set():
    """Re-uses the Filipino word list that baybayin_offline.py already
    loaded (the 42,585-word dictionary), so both directions use the SAME
    list and it isn't loaded twice. Returns None if it can't be found."""
    try:
        import baybayin_offline as bo
    except Exception:
        return None
    if hasattr(bo, 'warm_up'):
        try:
            bo.warm_up()
        except Exception:
            pass
    best = None
    for value in vars(bo).values():
        if isinstance(value, (set, frozenset)) and len(value) > 1000:
            if all(isinstance(w, str) for w in list(value)[:20]):
                if best is None or len(value) > len(best):
                    best = value
    return best


def _load_word_csv():
    """Reads the same Filipino word list the Baybayin side uses
    (Tagalog_words.csv in the python folder). Every alphabetic token in the
    file counts as a word, so the column layout does not matter."""
    for folder in (MODULE_DIR, os.path.join(MODULE_DIR, 'models')):
        for name in ('Tagalog_words.csv', 'tagalog_words.csv'):
            path = os.path.join(folder, name)
            if os.path.exists(path):
                words = set()
                with open(path, encoding='utf-8', errors='ignore') as f:
                    for line in f:
                        for token in re.findall(r'[A-Za-z]+', line):
                            words.add(token.lower())
                return words
    return set()


def warm_up_latin(word_set=None):
    """Loads model_latin.npz + latin_classes.json from this folder (or the
    .pkl files when testing on a PC), and the Filipino word list (given, or
    borrowed from baybayin_offline)."""
    global _WORD_SET, _REJECT_CFG
    if _LATIN_MODEL is None:
        # the app keeps its models in python/models/ (next to model_base.npz);
        # the python/ folder itself is also checked
        for folder in (os.path.join(MODULE_DIR, 'models'), MODULE_DIR):
            npz = os.path.join(folder, 'model_latin.npz')
            if os.path.exists(npz):
                load_latin_model(npz, os.path.join(folder, 'latin_classes.json'))
                break
        else:                               # PC testing with the .pkl files
            load_latin_model(os.path.join(MODULE_DIR, 'model_latin.pkl'),
                             os.path.join(MODULE_DIR, 'latin_metadata.pkl'))
        # optional: the measured limit for rejecting unknown letters
        for folder in (os.path.join(MODULE_DIR, 'models'), MODULE_DIR):
            cfg = os.path.join(folder, 'latin_reject.json')
            if os.path.exists(cfg):
                load_reject_config(cfg)
                break
        if _REJECT_CFG is None:          # no json: use the built-in double check
            _REJECT_CFG = {'score': 'prob', 'threshold': DEFAULT_SURE_LIMIT}
    if word_set is not None:
        _WORD_SET = {str(w).lower() for w in word_set}
    elif _WORD_SET is None:
        _WORD_SET = _load_word_csv() or None
        if not _WORD_SET:
            borrowed = _borrow_baybayin_word_set()
            if borrowed:
                _WORD_SET = {str(w).lower() for w in borrowed}
    return 'ok'


def recognize_latin_json(image_bytes, debug=False):
    """Easiest call from Kotlin/Chaquopy: bytes in, JSON string out.
    Never raises - errors come back as {"error": "..."} so the Dart side
    (OfflineRecognizer._decode) turns them into null."""
    try:
        if not isinstance(image_bytes, (bytes, bytearray)):
            image_bytes = bytes(image_bytes)          # Java byte[] -> bytes
        warm_up_latin()
        return json.dumps(preprocess_and_predict_latin(image_bytes, debug=debug),
                          ensure_ascii=False)
    except Exception as e:  # noqa: BLE001 - reported to the app, not raised
        return json.dumps({'error': f'{type(e).__name__}: {e}'})