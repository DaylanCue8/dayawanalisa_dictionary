import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'app_settings.dart';

/// Every vibration in the app goes through here, so the Settings switch
/// (Haptic feedback) is respected in one place.
///
/// On Android it drives the vibrator directly (MainActivity, channel
/// "dayaw/haptics"): Flutter's HapticFeedback goes through the system
/// "touch feedback" setting, which many phones switch off or ignore.
/// Elsewhere, or if the channel is missing, it falls back to
/// HapticFeedback.
class Haptics {
  Haptics._();

  static const _channel = MethodChannel('dayaw/haptics');

  /// A light tick: tabs, selectors, pickers.
  static Future<void> selection() =>
      _play('selection', HapticFeedback.selectionClick);

  /// A short tap: buttons, copy, next page.
  static Future<void> light() => _play('light', HapticFeedback.lightImpact);

  /// A firm knock: taking a photo.
  static Future<void> heavy() => _play('heavy', HapticFeedback.heavyImpact);

  /// Played when haptics are switched on, so the person feels it works.
  static Future<void> preview() =>
      _play('light', HapticFeedback.lightImpact, force: true);

  static Future<void> _play(
    String kind,
    Future<void> Function() fallback, {
    bool force = false,
  }) async {
    if (!force && !AppSettings.instance.hapticsEnabled) return;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      try {
        await _channel.invokeMethod<void>('vibrate', {'kind': kind});
        return;
      } catch (_) {
        // Channel unavailable (tests, old build): use the fallback.
      }
    }
    try {
      await fallback();
    } catch (_) {
      // No haptics on this device - never worth an error.
    }
  }
}
