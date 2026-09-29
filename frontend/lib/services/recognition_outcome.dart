/// What a recognizer response means for the app, in one place, so the
/// scan tab, the multi-page screen and the tests all read a response the
/// same way.
///
/// The on-phone recognizer (baybayin_offline.py) answers with one of the
/// statuses 'Success', 'Low_Confidence', 'No_Characters',
/// 'Blurry_Image', 'Invalid_Image' or 'Error'; OfflineRecognizer returns
/// null when the recognizer crashed or the bridge failed.
enum RecognitionOutcome {
  /// Letters were read (confidence above the recognizer's threshold).
  success,

  /// Letters were read, but the recognizer is not very sure.
  lowConfidence,

  /// The photo was fine but no Baybayin letters were found.
  noCharacters,

  /// The photo is too blurry to read.
  blurry,

  /// The bytes are not a readable image.
  invalidImage,

  /// No usable answer: crash, bridge failure, malformed or unknown reply.
  failed;

  /// Classifies a recognizer response (or null) into an outcome.
  static RecognitionOutcome of(Map<String, dynamic>? response) {
    if (response == null || response['error'] != null) return failed;
    final status = response['status']?.toString().toLowerCase() ?? '';
    switch (status) {
      case 'success':
        return success;
      case 'low_confidence':
        return lowConfidence;
      case 'no_characters':
        return noCharacters;
      case 'blurry_image':
        return blurry;
      case 'invalid_image':
        return invalidImage;
      default:
        return failed;
    }
  }

  /// True when there is text to show (success or low confidence).
  bool get hasText => this == success || this == lowConfidence;
}

/// The per-character detections of a response, sanitized once here so
/// the rest of the app can trust them. Never throws:
///   * a missing or non-list 'individual_detections' gives [];
///   * entries that aren't maps are dropped;
///   * a 'bbox' that isn't a valid box (see [isValidBox]) is removed, so
///     `d['bbox'] != null` always means four finite, ordered numbers;
///   * a non-numeric 'confidence' is replaced by 0.
List<Map<String, dynamic>> scannedDetections(Map<String, dynamic>? data) {
  final raw = data?['individual_detections'];
  if (raw is! List) return [];
  return [
    for (final entry in raw.whereType<Map>())
      {
        ...Map<String, dynamic>.from(entry),
        'bbox': isValidBox(entry['bbox'])
            ? Map<String, dynamic>.from(entry['bbox'] as Map)
            : null,
        'confidence': readNumber(
          Map<String, dynamic>.from(entry),
          'confidence',
        ),
      },
  ];
}

/// A usable bounding box: a map with numeric, finite x0 < x1 and y0 < y1.
bool isValidBox(Object? bbox) {
  if (bbox is! Map) return false;
  final values = [
    for (final k in const ['x0', 'y0', 'x1', 'y1']) bbox[k],
  ];
  if (values.any((v) => v is! num || !v.isFinite)) return false;
  final [x0, y0, x1, y1] = values.cast<num>();
  return x1 > x0 && y1 > y0;
}

/// Reads a number field (e.g. 'confidence', 'image_width') from a
/// response that may be missing it, hold null, or hold a numeric string.
/// Never throws; returns [fallback] instead.
double readNumber(
  Map<String, dynamic>? data,
  String key, {
  double fallback = 0,
}) {
  final value = data?[key];
  if (value is num) return value.isFinite ? value.toDouble() : fallback;
  if (value is String) return double.tryParse(value) ?? fallback;
  return fallback;
}
