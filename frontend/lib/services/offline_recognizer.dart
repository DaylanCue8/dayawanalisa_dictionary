import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, visibleForTesting;
import 'package:flutter/services.dart';

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
    try {
      final json = await channel
          .invokeMethod<String>('recognize', {
            'image': imageBytes,
            'inputType': inputType,
          })
          .timeout(timeout);
      return _decode(json, 'recognize');
    } catch (e) {
      debugPrint('[OFFLINE] recognize failed: $e');
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
