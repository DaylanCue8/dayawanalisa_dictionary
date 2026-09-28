import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart';

/// Talks to the offline (on-phone) Baybayin recognizer that runs in
/// Python through Chaquopy - see MainActivity.kt. Returns the same map the
/// Flask API used to return, so the rest of the app doesn't change.
class OfflineRecognizer {
  static const MethodChannel _channel = MethodChannel('dayaw/offline_ocr');

  /// Loads the models in the background (call once at start-up so the
  /// first scan is not slow). Safe to call more than once.
  static Future<void> warmUp() async {
    try {
      await _channel.invokeMethod<String>('warmUp');
    } catch (e) {
      debugPrint('[OFFLINE] warm-up failed: $e');
    }
  }

  /// Recognizes the Baybayin in [imageBytes]. [inputType] is 'pen' or
  /// 'marker'. Returns null if the recognizer crashed.
  static Future<Map<String, dynamic>?> recognize(
    Uint8List imageBytes, {
    required String inputType,
  }) async {
    try {
      final json = await _channel.invokeMethod<String>('recognize', {
        'image': imageBytes,
        'inputType': inputType,
      });
      if (json == null) return null;
      final data = Map<String, dynamic>.from(jsonDecode(json) as Map);
      if (data['error'] != null) {
        debugPrint('[OFFLINE] recognizer error: ${data['error']}');
        return null;
      }
      return data;
    } catch (e) {
      debugPrint('[OFFLINE] recognize failed: $e');
      return null;
    }
  }

  /// Tagalog -> Baybayin text mode (needs tagalog_to_baybayin.py on the phone).
  static Future<Map<String, dynamic>?> translateText(String text) async {
    try {
      final json = await _channel.invokeMethod<String>('translateText', {'text': text});
      if (json == null) return null;
      final data = Map<String, dynamic>.from(jsonDecode(json) as Map);
      return data['error'] != null ? null : data;
    } catch (e) {
      debugPrint('[OFFLINE] translateText failed: $e');
      return null;
    }
  }
}
