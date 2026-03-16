#!/usr/bin/env python3
# Copyright 2024 deepvariant-linux-arm64 contributors.
#
# BSD-3-Clause license (same as upstream DeepVariant).
"""Static INT8 quantization with synthetic calibration data.

For use during Docker build where no TFRecords are available.
Generates random float32 inputs in [-1, 1] matching the model's input shape.

Produces a usable INT8 model but accuracy should be validated with hap.py
before production use. Real-data calibration (quantize_static_onnx.py)
is preferred when TFRecords are available.

Usage:
    python scripts/synthetic_calibration.py \\
        --input /opt/models/wgs/model.onnx \\
        --output /opt/models/wgs/model_int8_static.onnx \\
        --saved_model_dir /opt/models/wgs \\
        --num_calibration_samples 200 \\
        --calibration_method percentile
"""

import argparse
import json
import os


def _check_ort_version():
    """Verify ORT >= 1.17.0 for ARM64 INT8 MLAS kernel support."""
    import onnxruntime as ort
    from packaging.version import Version
    if Version(ort.__version__) < Version('1.17.0'):
        raise RuntimeError(
            f'ONNX Runtime >= 1.17.0 required for ARM64 INT8 MLAS kernels '
            f'(SMMLA support). Found: {ort.__version__}')


class SyntheticCalibrationDataReader:
    """Generates random float32 inputs in [-1, 1] for ONNX static calibration.

    Implements the CalibrationDataReader interface (``get_next()`` returning
    ``{input_name: ndarray}`` or ``None`` when exhausted).

    Used during Docker build where no TFRecords are available. The synthetic
    data covers the same value range as real pileup images (preprocessed to
    [-1, 1] by DeepVariant's ``preprocess_images``).

    Args:
        model_path: Path to the FP32 ONNX model (used to read input tensor name).
        saved_model_dir: SavedModel directory containing ``example_info.json``.
        num_samples: Number of synthetic calibration samples to generate.
        seed: Random seed for reproducible calibration data. None for non-deterministic.
    """

    def __init__(self, model_path, saved_model_dir, num_samples=200, seed=42):
        """Initialize reader, resolve input name and shape from model artifacts."""
        import numpy as np
        import onnxruntime as ort

        self._np = np

        # Get input tensor name from the ONNX model
        sess = ort.InferenceSession(
            model_path, providers=['CPUExecutionProvider'])
        self._input_name = sess.get_inputs()[0].name
        del sess

        # Get input shape from example_info.json
        input_shape = [100, 221, 7]
        if saved_model_dir:
            info_path = os.path.join(saved_model_dir, 'example_info.json')
            if os.path.exists(info_path):
                with open(info_path) as f:
                    info = json.load(f)
                input_shape = info.get('shape', input_shape)

        self._input_shape = tuple(input_shape)
        self._num_samples = num_samples
        self._index = 0
        self._rng = np.random.RandomState(seed)

        print(f'Synthetic calibration: {num_samples} samples, '
              f'shape {list(input_shape)}, input name: {self._input_name}')

    def get_next(self):
        """Return next synthetic calibration sample as ``{name: ndarray}``.

        Returns:
            Dict mapping input tensor name to a float32 ndarray of shape
            ``(1, H, W, C)``, or ``None`` when all samples are exhausted.
        """
        if self._index >= self._num_samples:
            return None
        self._index += 1
        # Reason: uniform [-1, 1] matches DeepVariant preprocess_images range
        img = self._rng.uniform(
            -1, 1, (1,) + self._input_shape).astype(self._np.float32)
        return {self._input_name: img}

    def rewind(self):
        """Reset iterator to the beginning for re-calibration passes."""
        self._index = 0


def main():
    """Parse CLI args and run static INT8 quantization with synthetic data."""
    parser = argparse.ArgumentParser(
        description='Static INT8 quantization with synthetic calibration')
    parser.add_argument('--input', required=True,
                        help='Input FP32 ONNX model path')
    parser.add_argument('--output', required=True,
                        help='Output INT8 ONNX model path')
    parser.add_argument('--saved_model_dir',
                        help='SavedModel dir (for input shape from '
                             'example_info.json)')
    parser.add_argument('--num_calibration_samples', type=int, default=200,
                        help='Number of synthetic calibration samples '
                             '(default: 200)')
    parser.add_argument('--calibration_method', default='percentile',
                        choices=['percentile', 'entropy', 'minmax'],
                        help='Calibration method (default: percentile). '
                             'Do NOT use minmax for InceptionV3.')
    parser.add_argument('--percentile_value', type=float, default=99.99,
                        help='Percentile for clipping (default: 99.99)')
    parser.add_argument('--seed', type=int, default=42,
                        help='Random seed for reproducible calibration '
                             '(default: 42)')
    args = parser.parse_args()

    _check_ort_version()
    from onnxruntime.quantization import CalibrationMethod, QuantType
    from onnxruntime.quantization import quantize_static as ort_quantize_static

    # Map method name to enum
    method_map = {
        'percentile': CalibrationMethod.Percentile,
        'entropy': CalibrationMethod.Entropy,
        'minmax': CalibrationMethod.MinMax,
    }
    cal_method = method_map[args.calibration_method]

    if args.calibration_method == 'minmax':
        print('WARNING: MinMax calibration is NOT recommended for InceptionV3.')

    reader = SyntheticCalibrationDataReader(
        args.input, args.saved_model_dir, args.num_calibration_samples,
        args.seed)

    print(f'Static INT8 quantization: {args.input} -> {args.output}')
    print(f'  Calibration method: {args.calibration_method}')
    if args.calibration_method == 'percentile':
        print(f'  Percentile value: {args.percentile_value}')

    extra_options = {}
    if args.calibration_method == 'percentile':
        extra_options['CalibMovingAverage'] = True
        extra_options['CalibMovingAverageConstant'] = 0.01

    ort_quantize_static(
        args.input,
        args.output,
        reader,
        quant_format=None,
        activation_type=QuantType.QInt8,
        weight_type=QuantType.QInt8,
        calibrate_method=cal_method,
        extra_options=extra_options,
    )

    orig_size = os.path.getsize(args.input) / (1024 * 1024)
    quant_size = os.path.getsize(args.output) / (1024 * 1024)
    reduction = (1 - quant_size / orig_size) * 100
    print(f'\nOriginal: {orig_size:.1f} MB')
    print(f'Quantized: {quant_size:.1f} MB ({reduction:.1f}% smaller)')
    print('\nNOTE: Synthetic calibration used. Validate accuracy with hap.py')
    print('on HG002 before production use. Real-data calibration')
    print('(quantize_static_onnx.py) is preferred when TFRecords are available.')


if __name__ == '__main__':
    main()
