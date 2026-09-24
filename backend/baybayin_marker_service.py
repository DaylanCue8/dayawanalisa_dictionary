import io
import os
import re
import uuid

import cv2
import numpy as np
from PIL import Image as PILImage, ImageOps
from skimage.feature import hog

from baybayin_disambiguation import resolve_output_parts

TEMP_ROOT = 'temp_crops'


def decode_grayscale_exif_corrected(image_bytes):
    pil_img = PILImage.open(io.BytesIO(image_bytes))
    pil_img = ImageOps.exif_transpose(pil_img)
    pil_img = pil_img.convert('L')
    return np.array(pil_img)


# ---- BLUR DETECTION ----
# Mirrors the pen pipeline's approach. BLURRY_IMAGE_MESSAGE is its OWN
# constant here (the two pipelines share no code by design), but the
# string value must stay IDENTICAL to pen's for app.py's
# `text == BLURRY_IMAGE_MESSAGE` check to catch a blurry result from
# either pipeline.
BLUR_RESIZE_WIDTH = 800
# STARTING ESTIMATE - not yet calibrated for marker photos.
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


def ensure_dirs():
    os.makedirs(TEMP_ROOT, exist_ok=True)


_UNSAFE_FILENAME_CHARS = re.compile(r'[^A-Za-z0-9_-]')


def _safe_filename_part(text):
    """Makes a class name safe to use inside a filename."""
    return _UNSAFE_FILENAME_CHARS.sub('-', str(text)) or 'unknown'


def _crop_label_prefix(base_name, dia_name, kudlit_position):
    """
    Filename prefix describing what was detected:
      no kudlit      -> 'Ba'
      dot kudlit     -> 'Ba_Dot_Above' / 'Ba_Dot_Below'
      cross kudlit   -> 'Ba_Cross'   (both the 'X' and 'Cross' classes)
    """
    prefix = _safe_filename_part(base_name)
    dia = str(dia_name).strip().lower()
    if dia in ('', 'none'):
        return prefix
    if 'cross' in dia or 'x' in dia:
        return prefix + '_Cross'
    if 'dot' in dia:
        if kudlit_position in ('Above', 'Below'):
            return f'{prefix}_Dot_{kudlit_position}'
        return prefix + '_Dot'
    return f'{prefix}_{_safe_filename_part(dia_name)}'


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


# ---- MARKER: automatic deskew (runs BEFORE line-band detection) ----
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


# ---- MARKER: line-band isolation (runs BEFORE any segmentation) ----
LINE_BAND_SMOOTH_FRAC = 0.02
LINE_BAND_RUN_FRAC = 0.3
LINE_BAND_MERGE_GAP_FRAC = 0.6
LINE_BAND_MIN_GAP_PX = 5
LINE_BAND_EXPAND_FRAC = 0.5


def _row_letter_counts(binary_img):
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
    line), so a band boundary can never cut through a mark that sits
    further from its base than usual.
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


def group_line_boxes_into_words(boxes):
    if not boxes:
        return []
    row = sorted(boxes, key=lambda box: box[0])
    if len(row) == 1:
        return [row]

    gaps = [row[i][0] - row[i - 1][2] for i in range(1, len(row))]

    sorted_gaps = sorted(gaps)
    if len(sorted_gaps) > 1:
        jumps = [sorted_gaps[i + 1] - sorted_gaps[i] for i in range(len(sorted_gaps) - 1)]
        biggest_jump_idx = jumps.index(max(jumps))
        word_gap = (sorted_gaps[biggest_jump_idx] + sorted_gaps[biggest_jump_idx + 1]) / 2.0
    else:
        word_gap = max(10.0, sorted_gaps[0] * 2.0) if sorted_gaps else 10.0

    words = []
    current_word = [row[0]]
    for i in range(1, len(row)):
        gap = gaps[i - 1]
        if gap > word_gap:
            words.append(current_word)
            current_word = [row[i]]
        else:
            current_word.append(row[i])
    words.append(current_word)
    return words


# ---- MARKER: fixed initial-segmentation merge kernel ----
SEGMENT_MERGE_KERNEL = (5, 35)


def segment_glyphs(bin_img, pad=0, min_area=40, merge_kernel=SEGMENT_MERGE_KERNEL):
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


# Lowered from 0.5: hand-drawn crosses are often shifted to one side of
# the letter they belong to, so requiring half of the cross's width to
# sit directly above/below the letter left too many of them unmerged.
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


# A real base glyph is never this small next to its neighbors. Anything
# that is still this small AFTER the merge step is an orphaned fragment
# (e.g. a piece of a cross), and would otherwise be forced into some
# class by the SVM, which has no "noise" class.
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


def tight_crop_glyph_with_offset(crop_bin):
    points = cv2.findNonZero(crop_bin)
    if points is None:
        return None, None
    x, y, width, height = cv2.boundingRect(points)
    return (x, y), crop_bin[y:y + height, x:x + width]


GLYPH_CLUSTER_THICKNESS_MULTIPLIER = 4.5
GLYPH_CLUSTER_MIN_KERNEL = 10
GLYPH_CLUSTER_MAX_KERNEL = 45
GLYPH_REFINE_MIN_AREA = 20


def estimate_glyph_cluster_kernel(crop_bin):
    thickness = _estimate_stroke_thickness(crop_bin)
    size = int(round(thickness * GLYPH_CLUSTER_THICKNESS_MULTIPLIER))
    size = max(GLYPH_CLUSTER_MIN_KERNEL, min(size, GLYPH_CLUSTER_MAX_KERNEL))
    return (size, size)


def find_glyph_clusters(binary_img, kernel_size, min_area=GLYPH_REFINE_MIN_AREA):
    kernel = cv2.getStructuringElement(cv2.MORPH_RECT, kernel_size)
    dilated = cv2.dilate(binary_img, kernel, iterations=1)
    contours, _ = cv2.findContours(dilated, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)

    boxes = []
    for c in contours:
        x, y, w, h = cv2.boundingRect(c)
        if w * h < min_area:
            continue
        boxes.append((x, y, x + w, y + h))

    boxes.sort(key=lambda b: (b[0], b[1]))
    return boxes


def tighten_to_ink(binary_img, box):
    x0, y0, x1, y1 = box
    sub = binary_img[y0:y1, x0:x1]
    ys, xs = np.where(sub > 0)
    if len(xs) == 0:
        return box, sub
    new_box = (
        x0 + int(xs.min()), y0 + int(ys.min()),
        x0 + int(xs.max()) + 1, y0 + int(ys.max()) + 1,
    )
    tightened = sub[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    return new_box, tightened


def split_into_single_glyphs(crop_bin):
    kernel_size = estimate_glyph_cluster_kernel(crop_bin)
    clusters = find_glyph_clusters(crop_bin, kernel_size=kernel_size)
    if len(clusters) <= 1:
        h, w = crop_bin.shape[:2]
        return [((0, 0, w, h), crop_bin)], kernel_size
    return [tighten_to_ink(crop_bin, box) for box in clusters], kernel_size


# ---- MODEL INPUT NORMALIZATION ----
# Must produce EXACTLY the same framing as the training data, which was
# made by clean_raw_glyph: crop to ink, add a margin of MARGIN_FRAC *
# the longer side, pad to a centered square (no stretching), resize to
# 56x56 with INTER_AREA. MODEL_MARGIN_FRAC must stay equal to
# MARGIN_FRAC in the raw photo cleaner - if you change one, change the
# other, re-clean the dataset and retrain.
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


def _to_model_float(mask):
    return normalize_for_model(mask).astype(np.float32) / 255.0


def format_paragraph(lines):
    normalized = [line.strip().lower() for line in lines]
    normalized = [line for line in normalized if line]
    if not normalized:
        return ''
    first = normalized[0]
    normalized[0] = first[0].upper() + first[1:]
    return '\n'.join(normalized)


def _class_name(classes, prediction):
    return classes[int(prediction)] if not isinstance(prediction, str) else prediction


def _predict_with_confidence(model, features):
    prediction = model.predict(features)[0]
    if hasattr(model, 'predict_proba'):
        probabilities = model.predict_proba(features)[0]
        return prediction, float(np.max(probabilities))
    return prediction, 1.0


def _distance_transform_gap(labels, mask_label_ids, candidate_label_id):
    mask = np.isin(labels, mask_label_ids).astype(np.uint8) * 255
    inverted = np.where(mask > 0, 0, 255).astype(np.uint8)
    dist = cv2.distanceTransform(inverted, cv2.DIST_L2, 5)
    return float(dist[labels == candidate_label_id].min())


GAP_THICKNESS_MULTIPLIER = 0.5  # TODO: still being calibrated
MAX_GAP_THRESHOLD_PIXELS = 5.0
MIN_PIXELS_FOR_SHAPE_ANALYSIS = 16
SOLIDITY_THRESHOLD = 0.80


def separate_base_and_diacritic(labels, stats, num_labels):
    areas = [(i, stats[i, cv2.CC_STAT_AREA]) for i in range(1, num_labels)]
    areas.sort(key=lambda t: t[1], reverse=True)

    base_idx_list = [areas[0][0]]
    remaining = [idx for idx, _ in areas[1:]]

    largest_mask = (labels == areas[0][0]).astype(np.uint8) * 255
    stroke_thickness = _estimate_stroke_thickness(largest_mask)
    gap_threshold = min(stroke_thickness * GAP_THICKNESS_MULTIPLIER, MAX_GAP_THRESHOLD_PIXELS)

    keep_merging = True
    while keep_merging and remaining:
        keep_merging = False
        still_remaining = []
        for idx in remaining:
            gap = _distance_transform_gap(labels, base_idx_list, idx)
            if gap <= gap_threshold:
                base_idx_list.append(idx)
                keep_merging = True
            else:
                still_remaining.append(idx)
        remaining = still_remaining

    dia_idx = None
    if remaining:
        remaining_by_area = sorted(
            remaining, key=lambda idx: stats[idx, cv2.CC_STAT_AREA], reverse=True
        )
        dia_idx = remaining_by_area[0]

    return base_idx_list, dia_idx, gap_threshold


AMBIGUOUS_CONSONANT_SLOTS = {'DA': '{d/r}'}


def classify_glyph(native_crop, base_model, dia_model, base_classes, dia_classes, debug=False):
    num_labels, labels, stats, centroids = cv2.connectedComponentsWithStats(native_crop)
    predicted_base_name = 'Unknown'
    predicted_dia_name = 'None'
    position = 'None'
    base_confidence = 0.0
    dia_confidence = 0.0

    if num_labels <= 1:
        return predicted_base_name, predicted_dia_name, '', 0.0, position

    # Whole glyph (base + any marks), framed exactly like the training set
    whole_mask = np.where(native_crop > 0, 255, 0).astype(np.uint8)
    whole_norm = _to_model_float(whole_mask)
    hog_whole = hog(
        whole_norm, orientations=9, pixels_per_cell=(8, 8),
        cells_per_block=(2, 2), transform_sqrt=True, visualize=False,
    ).reshape(1, -1)
    whole_prediction, whole_confidence = _predict_with_confidence(base_model, hog_whole)
    whole_base_name = _class_name(base_classes, whole_prediction)

    base_idx_list, dia_idx, gap_threshold_used = separate_base_and_diacritic(labels, stats, num_labels)

    if dia_idx is None:
        predicted_base_name = whole_base_name
        base_confidence = whole_confidence
        if debug:
            print(f"  [marker debug] no diacritic split "
                  f"(gap_threshold_used={gap_threshold_used:.2f}); "
                  f"whole_crop_pred='{whole_base_name}' ({whole_confidence:.2f})")
    else:
        base_mask_full = np.isin(labels, base_idx_list).astype(np.uint8) * 255
        coords = cv2.findNonZero(base_mask_full)
        bx, by, bw, bh = cv2.boundingRect(coords)  # still needed for position check
        base_norm = _to_model_float(base_mask_full)

        dx, dy, dw, dh, _ = stats[dia_idx]
        if dw == 0 or dh == 0:
            predicted_base_name = whole_base_name
            base_confidence = whole_confidence
            return predicted_base_name, predicted_dia_name, predicted_base_name, base_confidence, position

        dia_mask_full = (labels == dia_idx).astype(np.uint8) * 255
        dia_crop = dia_mask_full[dy:dy + dh, dx:dx + dw]

        # Solidity check only - this upscaled crop is NOT fed to the model
        dia_upscaled = cv2.resize(dia_crop, (40, 40), interpolation=cv2.INTER_CUBIC)
        _, dia_upscaled = cv2.threshold(dia_upscaled, 127, 255, cv2.THRESH_BINARY)

        contours, _ = cv2.findContours(
            dia_upscaled, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE
        )
        if contours:
            largest_contour = max(contours, key=cv2.contourArea)
            hull_area = cv2.contourArea(cv2.convexHull(largest_contour))
            solidity = (
                cv2.contourArea(largest_contour) / hull_area
                if hull_area > 0 else 1.0
            )
        else:
            solidity = 1.0

        dia_norm = _to_model_float(dia_mask_full)

        hog_base = hog(
            base_norm, orientations=9, pixels_per_cell=(8, 8),
            cells_per_block=(2, 2), transform_sqrt=True, visualize=False,
        ).reshape(1, -1)
        hog_dia = hog(
            dia_norm, orientations=9, pixels_per_cell=(4, 4),
            cells_per_block=(1, 1), transform_sqrt=True, visualize=False,
        ).reshape(1, -1)
        base_prediction, base_confidence = _predict_with_confidence(base_model, hog_base)
        dia_prediction, dia_confidence = _predict_with_confidence(dia_model, hog_dia)
        predicted_base_name = _class_name(base_classes, base_prediction)
        predicted_dia_name = _class_name(dia_classes, dia_prediction)
        svm_raw_dia_prediction = predicted_dia_name

        base_centroid_y = by + (bh / 2.0)
        position = 'Above' if centroids[dia_idx][1] < base_centroid_y else 'Below'

        is_too_small_for_shape_analysis = (dw * dh) < MIN_PIXELS_FOR_SHAPE_ANALYSIS

        if is_too_small_for_shape_analysis:
            predicted_dia_name = 'Dot'
        elif solidity < SOLIDITY_THRESHOLD:
            available_classes = [str(value).lower() for value in dia_classes]
            if 'x' in available_classes:
                predicted_dia_name = 'X'
            elif 'cross' in available_classes:
                predicted_dia_name = 'Cross'
        else:
            predicted_dia_name = 'Dot'

        force_for_vowel = whole_base_name in ('A', 'EI', 'OU') and whole_confidence >= base_confidence
        prefer_for_fragment = whole_confidence >= base_confidence and is_too_small_for_shape_analysis

        if force_for_vowel or prefer_for_fragment:
            if debug:
                reason = 'vowel' if force_for_vowel else 'small stray fragment'
                print(f"  [marker debug] SPLIT CORRECTION ({reason}): split gave "
                      f"'{svm_raw_dia_prediction}' diacritic on base "
                      f"'{predicted_base_name}' ({base_confidence:.2f}), but whole-crop "
                      f"reading '{whole_base_name}' ({whole_confidence:.2f}) is at least "
                      f"as confident -> using whole-crop result instead")
            predicted_base_name = whole_base_name
            predicted_dia_name = 'None'
            position = 'None'
            base_confidence = whole_confidence
            dia_confidence = 0.0

        if debug:
            print(f"  [marker debug] dw={dw}, dh={dh}, area={dw * dh}, "
                  f"solidity={solidity:.2f} (threshold={SOLIDITY_THRESHOLD}), "
                  f"too_small={is_too_small_for_shape_analysis}, "
                  f"gap_threshold_used={gap_threshold_used:.2f}, "
                  f"split_svm_pred='{svm_raw_dia_prediction}', "
                  f"whole_crop_pred='{whole_base_name}' ({whole_confidence:.2f}), "
                  f"position='{position}'")

    final_output_text = predicted_base_name
    if predicted_base_name == 'EI':
        final_output_text = '{e/i}'
    elif predicted_base_name == 'OU':
        final_output_text = '{o/u}'
    elif predicted_base_name != 'A':
        dia_clean = predicted_dia_name.lower()
        base_root = predicted_base_name[:-1]
        normalized_base_name = predicted_base_name.strip().upper()
        consonant_slot = AMBIGUOUS_CONSONANT_SLOTS.get(normalized_base_name, base_root)
        if 'cross' in dia_clean or 'x' in dia_clean:
            final_output_text = consonant_slot
        elif position == 'Above' and 'dot' in dia_clean:
            final_output_text = consonant_slot + '{e/i}'
        elif position == 'Below' and 'dot' in dia_clean:
            final_output_text = consonant_slot + '{o/u}'
        elif normalized_base_name in AMBIGUOUS_CONSONANT_SLOTS:
            final_output_text = consonant_slot + predicted_base_name[-1]

    confidence = base_confidence
    if predicted_dia_name != 'None':
        confidence = min(base_confidence, dia_confidence)
    return predicted_base_name, predicted_dia_name, final_output_text, confidence, position


_AMBIGUITY_SLOT_PATTERN = re.compile(r'\{[a-z]/[a-z]\}')


def _resolved_length(char_fragment):
    return len(_AMBIGUITY_SLOT_PATTERN.sub('x', char_fragment))


def apply_resolved_word_to_chars(char_fragments, resolved_word):
    out = []
    position = 0
    for fragment in char_fragments:
        length = _resolved_length(fragment)
        out.append(resolved_word[position:position + length])
        position += length
    return out


def preprocess_and_predict(image_bytes, session_id, base_model, dia_model, base_classes, dia_classes,
                           filipino_word_set=None, debug=False):
    if base_model is None or dia_model is None:
        raise ValueError('Baybayin base and diacritic models not loaded')

    try:
        image = decode_grayscale_exif_corrected(image_bytes)
    except Exception:
        image = None
    if image is None:
        return 'Error', 0.0, [], {'width': 0, 'height': 0}

    image_height, image_width = image.shape[:2]

    # ---- BLUR CHECK: on the raw photo, before any processing ----
    blur_score = compute_blur_score(image)
    if debug:
        print(f"  [marker debug] blur_score={blur_score:.2f} (threshold={BLUR_VARIANCE_THRESHOLD})")
    if blur_score < BLUR_VARIANCE_THRESHOLD:
        return (
            BLURRY_IMAGE_MESSAGE, 0.0, [],
            {'width': image_width, 'height': image_height},
        )

    blur_size = min(101, max(15, (min(image.shape) // 3) | 1))
    background = cv2.GaussianBlur(image, (blur_size, blur_size), 0)
    normalized = cv2.divide(image, background, scale=255)
    binary = preprocess_image(normalized)

    skew_angle = estimate_skew_angle(binary)
    if debug:
        print(f"  [marker debug] estimated skew angle: {skew_angle:.2f} degrees")
    rotation_center = (image_width / 2.0, image_height / 2.0)
    rotation_matrix = cv2.getRotationMatrix2D(rotation_center, skew_angle, 1.0)
    rotation_matrix_inv = cv2.invertAffineTransform(rotation_matrix)
    binary = cv2.warpAffine(
        binary, rotation_matrix, (image_width, image_height),
        flags=cv2.INTER_NEAREST, borderValue=0,
    )

    line_bands = find_line_bands(binary)
    if debug:
        print(f"  [marker debug] line_bands_found={line_bands}")
    if not line_bands:
        return 'No characters detected', 0.0, [], {'width': image_width, 'height': image_height}

    # Each connected ink component is assigned to ONE line, so a cross
    # hanging between two tight lines is never sliced in half.
    line_masks = split_into_line_masks(binary, line_bands)

    # text_lines holds (words, line_mask) pairs. Later cropping reads
    # from the line's own mask, not the whole page, so ink from a
    # neighboring line can't leak into a glyph's crop.
    text_lines = []
    for (band_y0, band_y1), full_mask in zip(line_bands, line_masks):
        rows_with_ink = np.where(full_mask.any(axis=1))[0]
        if rows_with_ink.size == 0:
            continue
        # Use the real vertical extent of this line's ink (its marks may
        # hang beyond the original band).
        band_y0, band_y1 = int(rows_with_ink.min()), int(rows_with_ink.max()) + 1
        line_bin = full_mask[band_y0:band_y1, :]

        line_boxes = tighten_boxes(line_bin, segment_glyphs(line_bin), pad=0)
        boxes_before_merge = len(line_boxes)
        line_boxes = merge_stray_diacritic_boxes(line_boxes)
        if debug and len(line_boxes) != boxes_before_merge:
            print(f"  [marker debug] band=({band_y0},{band_y1}) "
                  f"merge_stray_diacritic_boxes: {boxes_before_merge} -> {len(line_boxes)}")

        boxes_before_orphan_filter = len(line_boxes)
        line_boxes = drop_orphan_fragments(line_boxes)
        if debug and len(line_boxes) != boxes_before_orphan_filter:
            print(f"  [marker debug] band=({band_y0},{band_y1}) "
                  f"drop_orphan_fragments: {boxes_before_orphan_filter} -> {len(line_boxes)}")

        if not line_boxes:
            continue

        line_boxes = [
            (x0, y0 + band_y0, x1, y1 + band_y0) for (x0, y0, x1, y1) in line_boxes
        ]
        words = group_line_boxes_into_words(line_boxes)
        if words:
            text_lines.append((words, full_mask))

    if debug:
        print(f"  [marker debug] paragraph structure: {len(text_lines)} line(s), "
              f"words per line = {[len(words) for words, _ in text_lines]}")

    if not text_lines:
        return 'No characters detected', 0.0, [], {'width': image_width, 'height': image_height}

    session_dir = os.path.join(TEMP_ROOT, f'session_{session_id}')
    os.makedirs(session_dir, exist_ok=True)
    results = []
    output_parts = []
    noise_confidence_threshold = 0.20

    result_indices_per_line = []

    crop_index = 0
    for line, line_mask in text_lines:
        line_words = []
        line_word_indices = []
        for word_group in line:
            word_parts = []
            word_result_indices = []
            for x0, y0, x1, y1 in word_group:
                crop_offset, crop = tight_crop_glyph_with_offset(line_mask[y0:y1, x0:x1])
                if crop is None:
                    continue
                tight_abs_x = x0 + crop_offset[0]
                tight_abs_y = y0 + crop_offset[1]

                single_glyph_crops, kernel_used = split_into_single_glyphs(crop)
                if debug:
                    print(f"  [marker debug] glyph cluster kernel used: {kernel_used} "
                          f"-> {len(single_glyph_crops)} piece(s)")

                for local_box, glyph_crop in single_glyph_crops:
                    base_name, dia_name, final_text, confidence, kudlit_position = classify_glyph(
                        glyph_crop, base_model, dia_model, base_classes, dia_classes, debug=debug,
                    )
                    if base_name == 'Unknown':
                        continue
                    if confidence < noise_confidence_threshold:
                        continue

                    lx0, ly0, lx1, ly1 = local_box
                    abs_x0 = tight_abs_x + lx0
                    abs_y0 = tight_abs_y + ly0
                    abs_x1 = tight_abs_x + lx1
                    abs_y1 = tight_abs_y + ly1

                    orig_x0, orig_y0, orig_x1, orig_y1 = map_box_to_original(
                        rotation_matrix_inv, abs_x0, abs_y0, abs_x1, abs_y1
                    )

                    # Named after what the model saw, e.g. 'A_136_6103f3.png',
                    # 'Ba_Dot_Above_12_efba0c.png' or 'Ba_Cross_12_efba0c.png'
                    # (class[_kudlit[_position]]_cropIndex_randomId). Built from
                    # base_name/dia_name/position and NOT from final_text, because
                    # final_text can still hold ambiguity slots like '{d/r}a'
                    # whose '/' would turn into a missing subfolder and make
                    # cv2.imwrite silently fail. Saved as PNG (lossless) in the
                    # same 56x56 training format, so archived crops can go
                    # straight back into the dataset.
                    crop_path = os.path.join(
                        session_dir,
                        f'{_crop_label_prefix(base_name, dia_name, kudlit_position)}'
                        f'_{crop_index}_{uuid.uuid4().hex[:6]}.png'
                    )
                    cv2.imwrite(crop_path, normalize_for_model(glyph_crop))
                    word_result_indices.append(len(results))
                    results.append({
                        'char': final_text,
                        'base': base_name,
                        'diacritic': dia_name,
                        'confidence': round(confidence * 100, 2),
                        'is_eligible': True,
                        'temp_path': crop_path,
                        'bbox': {
                            'x0': int(round(orig_x0)),
                            'y0': int(round(orig_y0)),
                            'x1': int(round(orig_x1)),
                            'y1': int(round(orig_y1)),
                        },
                    })
                    word_parts.append(final_text)
                    crop_index += 1

            if word_parts:
                line_words.append(''.join(word_parts))
                line_word_indices.append(word_result_indices)

        if line_words:
            output_parts.append(' '.join(line_words))
            result_indices_per_line.append(line_word_indices)

    if not results:
        return 'No characters detected', 0.0, [], {'width': image_width, 'height': image_height}

    if filipino_word_set:
        resolved_lines, resolution_log = resolve_output_parts(output_parts, filipino_word_set)

        for line_index, resolved_line in enumerate(resolved_lines):
            if line_index >= len(result_indices_per_line):
                break
            word_index_groups = result_indices_per_line[line_index]
            for word_index, resolved_word in enumerate(resolved_line.split(' ')):
                if word_index >= len(word_index_groups):
                    break
                indices = word_index_groups[word_index]
                fragments = [results[i]['char'] for i in indices]
                resolved_fragments = apply_resolved_word_to_chars(fragments, resolved_word)
                for result_index, resolved_fragment in zip(indices, resolved_fragments):
                    results[result_index]['char'] = resolved_fragment

        if debug:
            status_counts = {}
            for entry in resolution_log:
                status_counts[entry['status']] = status_counts.get(entry['status'], 0) + 1
                print(f"  [marker debug] DISAMBIGUATION: '{entry['word']}' -> "
                      f"'{entry['resolved']}' (via {entry['status']})")
            print(f"  [marker debug] disambiguation totals: {status_counts}")

        output_parts = resolved_lines

    average_confidence = (
        round(float(np.mean([item['confidence'] for item in results])), 2)
        if results else 0.0
    )
    image_dims = {'width': image_width, 'height': image_height}
    return format_paragraph(output_parts), average_confidence, results, image_dims