import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';

/// TESTING ONLY (Objective 3 evaluation). When true, every scan saves the
/// exact (cropped) image that was sent to the recognizer:
///   1. to the phone Gallery, album "DAYAW Eval"  (easy to get the photos)
///   2. to <app files>/eval/ together with a .txt of what the app read and
///      a running eval_log.csv
/// Set to false before releasing the app so users' photos are never kept.
const bool kSaveEvalCopies = false;

/// Talks to the offline (on-phone) Baybayin recognizer that runs in
/// Python through Chaquopy - see MainActivity.kt. Returns the same map the
/// Flask API used to return, so the rest of the app doesn't change.
///
/// Error handling contract: these methods never throw. Every failure
/// (empty input, channel/plugin error, Python crash, timeout, null or
/// malformed reply) comes back as null, which RecognitionOutcome.of()
/// classifies as `failed`.
class OfflineRecognizer {
  @visibleForTesting
  static const MethodChannel channel = MethodChannel('dayaw/offline_ocr');

  /// Longest a single recognition may take before it's treated as failed,
  /// so a stuck Python call can't leave the scan spinner running forever.
  @visibleForTesting
  static Duration timeout = const Duration(seconds: 60);

  /// Name of the Gallery album the evaluation copies go into.
  static const String evalAlbum = 'DAYAW Eval';

  /// DEBUG: after every scan, one message saying whether the image was
  /// saved (and where), or why not. The scan screen shows it as a
  /// SnackBar so you can check it on the phone without a PC.
  static final StreamController<String> _evalStatus =
      StreamController<String>.broadcast();
  static Stream<String> get evalStatus => _evalStatus.stream;

  /// Loads the models in the background (call once at start-up so the
  /// first scan is not slow). Safe to call more than once.
  static Future<void> warmUp() async {
    try {
      await channel.invokeMethod<String>('warmUp');
    } catch (e) {
      debugPrint('[OFFLINE] warm-up failed: $e');
    }
  }

  /// Recognizes the Baybayin in [imageBytes]. [inputType] is 'pen' or
  /// 'marker'. Returns null if there was nothing to read or the
  /// recognizer failed.
  static Future<Map<String, dynamic>?> recognize(
    Uint8List imageBytes, {
    required String inputType,
  }) async {
    if (imageBytes.isEmpty) {
      debugPrint('[OFFLINE] recognize skipped: empty image');
      return null;
    }
    Map<String, dynamic>? data;
    try {
      final json = await channel
          .invokeMethod<String>('recognize', {
            'image': imageBytes,
            'inputType': inputType,
          })
          .timeout(timeout);
      data = _decode(json, 'recognize');
    } catch (e) {
      debugPrint('[OFFLINE] recognize failed: $e');
      data = null;
    }
    // Saved even when nothing was read - a failed scan is still a result
    // for Objective 3. Not awaited, so the result screen isn't delayed.
    unawaited(_saveEvalCopy(imageBytes, inputType, data));
    return data;
  }

  // ---------------------------------------------------------------------
  // Objective 3: keep a copy of every cropped image
  // ---------------------------------------------------------------------

  /// Saves the exact bytes given to the recognizer (the cropped image).
  /// File name: DAYAW_<yyyyMMdd_HHmmss>_<pen|marker>.jpg
  static Future<void> _saveEvalCopy(
    Uint8List imageBytes,
    String inputType,
    Map<String, dynamic>? data,
  ) async {
    if (!kSaveEvalCopies) return;
    final name = 'DAYAW_${_timestamp()}_$inputType';
    final text = (data?['translated_text'] ?? '').toString();
    final status = (data?['status'] ?? 'Failed').toString();
    final confidence = (data?['confidence'] ?? '').toString();

    String gallery;
    String folderResult;

    // 1) Phone Gallery -> album "DAYAW Eval" (Pictures/DAYAW Eval).
    try {
      if (!await Gal.hasAccess(toAlbum: true)) {
        await Gal.requestAccess(toAlbum: true);
      }
      await Gal.putImageBytes(imageBytes, album: evalAlbum, name: name);
      gallery = 'Gallery OK (Pictures/$evalAlbum)';
    } catch (e) {
      gallery = 'Gallery FAILED: $e';
    }

    // 2) App folder: image + recognized text + one log line.
    try {
      final base = await getExternalStorageDirectory();
      if (base == null) throw Exception('no external storage');
      final folder = Directory('${base.path}/eval');
      await folder.create(recursive: true);
      await File('${folder.path}/$name.jpg').writeAsBytes(imageBytes);
      await File('${folder.path}/$name.txt').writeAsString(text);

      final log = File('${folder.path}/eval_log.csv');
      if (!await log.exists()) {
        await log.writeAsString('file,input_type,status,confidence,text\n');
      }
      await log.writeAsString(
        '${_csv('$name.jpg')},${_csv(inputType)},${_csv(status)},'
        '${_csv(confidence)},${_csv(text)}\n',
        mode: FileMode.append,
      );
      folderResult = 'App folder OK (${folder.path})';
    } catch (e) {
      folderResult = 'App folder FAILED: $e';
    }

    final message = '[EVAL] $name.jpg\n$gallery\n$folderResult';
    debugPrint(message);
    _evalStatus.add(message);
  }

  static String _timestamp() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${n.year}${two(n.month)}${two(n.day)}_'
        '${two(n.hour)}${two(n.minute)}${two(n.second)}'
        '_${n.millisecond.toString().padLeft(3, '0')}';
  }

  /// Quotes a value for CSV (keeps commas and line breaks inside one cell).
  static String _csv(String v) => '"${v.replaceAll('"', '""')}"';

  // ---------------------------------------------------------------------

  /// Classifies an already-generated HOG feature vector on iOS.
  /// Image preprocessing and HOG generation will be connected after the
  /// native model-loading slice is validated.
  static Future<Map<String, dynamic>?> classifyFeatures(
    List<double> features, {
    bool diacritic = false,
  }) async {
    try {
      final result = await channel.invokeMethod<Map<Object?, Object?>>(
        'classifyFeatures',
        {'features': features, 'diacritic': diacritic},
      );
      return result == null ? null : Map<String, dynamic>.from(result);
    } catch (e) {
      debugPrint('[OFFLINE] feature classification failed: $e');
      return null;
    }
  }

  /// Tagalog -> Baybayin text mode (needs tagalog_to_baybayin.py on the phone).
  static Future<Map<String, dynamic>?> translateText(String text) async {
    try {
      final json = await channel
          .invokeMethod<String>('translateText', {'text': text})
          .timeout(timeout);
      return _decode(json, 'translateText');
    } catch (e) {
      debugPrint('[OFFLINE] translateText failed: $e');
      return null;
    }
  }

  /// JSON reply -> map; null for a null reply, anything that isn't a JSON
  /// object, or a reply carrying an 'error'.
  static Map<String, dynamic>? _decode(String? json, String method) {
    if (json == null || json.isEmpty) return null;
    final decoded = jsonDecode(json);
    if (decoded is! Map) {
      debugPrint('[OFFLINE] $method: reply is not a JSON object');
      return null;
    }
    final data = Map<String, dynamic>.from(decoded);
    if (data['error'] != null) {
      debugPrint('[OFFLINE] $method error: ${data['error']}');
      return null;
    }
    return data;
  }
}