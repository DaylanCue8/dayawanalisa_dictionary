"""
NumPy-only HOG, written to give the SAME numbers as
skimage.feature.hog(image, orientations, pixels_per_cell, cells_per_block,
                    transform_sqrt=True, block_norm='L2-Hys', feature_vector=True)
for a 2-D grayscale float image.

Used on the phone (Chaquopy) so the app does not need scikit-image.
The services import it automatically when scikit-image is missing:
    try:
        from skimage.feature import hog
    except ImportError:
        from baybayin_hog import hog
Verify it against scikit-image with export_models_for_android.py.
"""
import numpy as np


def _normalize_block_l2hys(block, eps=1e-5):
    out = block / np.sqrt(np.sum(block ** 2) + eps ** 2)
    out = np.minimum(out, 0.2)
    out = out / np.sqrt(np.sum(out ** 2) + eps ** 2)
    return out


def hog(image, orientations=9, pixels_per_cell=(8, 8), cells_per_block=(3, 3),
        block_norm='L2-Hys', visualize=False, transform_sqrt=False,
        feature_vector=True, **_unused):
    if visualize:
        raise NotImplementedError('baybayin_hog.hog does not draw the HOG image')
    if block_norm != 'L2-Hys':
        raise NotImplementedError('only block_norm="L2-Hys" is implemented')

    image = np.atleast_2d(np.asarray(image))
    if image.ndim != 2:
        raise ValueError('baybayin_hog.hog expects a 2-D grayscale image')
    # scikit-image keeps float32 input as float32 (float64 for other types)
    dtype = np.float32 if image.dtype == np.float32 else np.float64
    image = image.astype(dtype, copy=False)

    if transform_sqrt:
        image = np.sqrt(image)

    # gradients: central difference, 0 on the border rows/columns
    g_row = np.zeros_like(image)
    g_col = np.zeros_like(image)
    g_row[1:-1, :] = image[2:, :] - image[:-2, :]
    g_col[:, 1:-1] = image[:, 2:] - image[:, :-2]

    s_row, s_col = image.shape
    c_row, c_col = pixels_per_cell
    b_row, b_col = cells_per_block
    n_cells_row = int(s_row // c_row)
    n_cells_col = int(s_col // c_col)

    # like scikit-image: gradients are computed in the image's dtype, then
    # everything from here on is float64 (the histogram step is float64)
    g_row = g_row.astype(np.float64)
    g_col = g_col.astype(np.float64)
    magnitude = np.hypot(g_col, g_row)
    orientation = np.rad2deg(np.arctan2(g_row, g_col)) % 180

    # orientation bin of each pixel: [i*180/n, (i+1)*180/n)
    bin_width = 180.0 / orientations
    histogram = np.zeros((n_cells_row, n_cells_col, orientations), dtype=np.float64)
    used_rows = n_cells_row * c_row
    used_cols = n_cells_col * c_col
    mag = magnitude[:used_rows, :used_cols]
    ori = orientation[:used_rows, :used_cols]
    for i in range(orientations):
        start = bin_width * (i + 1)
        end = bin_width * i
        in_bin = (ori < start) & (ori >= end)
        masked = np.where(in_bin, mag, 0.0)
        cell_sums = masked.reshape(n_cells_row, c_row, n_cells_col, c_col).sum(axis=(1, 3))
        histogram[:, :, i] = cell_sums / (c_row * c_col)

    n_blocks_row = (n_cells_row - b_row) + 1
    n_blocks_col = (n_cells_col - b_col) + 1
    blocks = np.zeros((n_blocks_row, n_blocks_col, b_row, b_col, orientations), dtype=dtype)
    for r in range(n_blocks_row):
        for c in range(n_blocks_col):
            blocks[r, c] = _normalize_block_l2hys(histogram[r:r + b_row, c:c + b_col, :])

    if feature_vector:
        return blocks.ravel()
    return blocks
