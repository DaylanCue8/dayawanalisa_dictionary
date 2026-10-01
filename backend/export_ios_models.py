"""Export the Android NPZ SVMs to a simple little-endian iOS format."""

from pathlib import Path
import struct

import numpy as np


MAGIC = b'DAYAWNP1'
MODEL_NAMES = ('model_base', 'model_dia')
MODEL_DIR = Path(__file__).parent.parent / 'frontend' / 'android' / 'app' / 'src' / 'main' / 'python' / 'models'
OUTPUT_DIR = Path(__file__).parent.parent / 'frontend' / 'ios' / 'Runner' / 'Models'


def _array_bytes(array: np.ndarray) -> tuple[int, tuple[int, ...], bytes]:
    if array.dtype.kind == 'f':
        dtype_code = 1 if array.dtype.itemsize == 4 else 2
        array = array.astype('<f4' if dtype_code == 1 else '<f8', copy=False)
    elif array.dtype.kind in 'iu':
        dtype_code = 3
        array = array.astype('<i8', copy=False)
    else:
        raise ValueError(f'Unsupported dtype: {array.dtype}')
    return dtype_code, array.shape, np.ascontiguousarray(array).tobytes()


def export_model(name: str) -> Path:
    source = MODEL_DIR / f'{name}.npz'
    destination = OUTPUT_DIR / f'{name}.bin'
    with np.load(source) as archive, destination.open('wb') as output:
        output.write(MAGIC)
        output.write(struct.pack('<I', len(archive.files)))
        for key in archive.files:
            dtype_code, shape, payload = _array_bytes(archive[key])
            encoded_name = key.encode('ascii')
            output.write(struct.pack('<I', len(encoded_name)))
            output.write(encoded_name)
            output.write(struct.pack('<BB', dtype_code, len(shape)))
            output.write(struct.pack(f'<{len(shape)}Q', *shape))
            output.write(struct.pack('<Q', len(payload)))
            output.write(payload)
    return destination


def main() -> None:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    for name in MODEL_NAMES:
        destination = export_model(name)
        print(f'{destination.name}: {destination.stat().st_size} bytes')


if __name__ == '__main__':
    main()