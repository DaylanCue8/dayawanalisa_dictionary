import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide user preferences, saved on the device so they survive
/// restarts. Screens read [AppSettings.instance]; widgets that must react
/// to a change (e.g. the glass look) listen to it.
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  static const defaultCameraInputType = 'marker';
  static const defaultResultFilter = 'HOG';
  static const defaultMinConfidence = 23.0;

  SharedPreferences? _prefs;

  String _cameraInputType = defaultCameraInputType;
  bool _cameraGridByDefault = false;
  String _resultFilter = defaultResultFilter;
  bool _showBoundingBoxesByDefault = false;
  double _minConfidence = defaultMinConfidence;
  bool _hapticsEnabled = true;
  bool _reduceTransparency = false;
  bool _hasSeenIntro = false;

  /// Whether the intro screens were already shown (first launch only).
  bool get hasSeenIntro => _hasSeenIntro;
  set hasSeenIntro(bool value) =>
      _update(() => _hasSeenIntro = value, 'hasSeenIntro', value);

  /// 'marker' or 'pen' - which input type the camera screen starts on.
  String get cameraInputType => _cameraInputType;
  bool get cameraGridByDefault => _cameraGridByDefault;

  /// 'Raw', 'Black and White' or 'HOG' - the results page's first filter.
  String get resultFilter => _resultFilter;
  bool get showBoundingBoxesByDefault => _showBoundingBoxesByDefault;

  /// Detections below this confidence (0-100) are left out of the
  /// Character Breakdown and the bounding boxes.
  double get minConfidence => _minConfidence;
  bool get hapticsEnabled => _hapticsEnabled;

  /// Swaps the frosted glass blur for solid panels: easier to read and
  /// lighter on slower phones.
  bool get reduceTransparency => _reduceTransparency;

  Future<void> load() async {
    try {
      final prefs = _prefs = await SharedPreferences.getInstance();
      _cameraInputType =
          prefs.getString('cameraInputType') ?? defaultCameraInputType;
      _cameraGridByDefault = prefs.getBool('cameraGridByDefault') ?? false;
      _resultFilter = prefs.getString('resultFilter') ?? defaultResultFilter;
      _showBoundingBoxesByDefault =
          prefs.getBool('showBoundingBoxesByDefault') ?? false;
      _minConfidence = prefs.getDouble('minConfidence') ?? defaultMinConfidence;
      _hapticsEnabled = prefs.getBool('hapticsEnabled') ?? true;
      _reduceTransparency = prefs.getBool('reduceTransparency') ?? false;
      _hasSeenIntro = prefs.getBool('hasSeenIntro') ?? false;
    } catch (_) {
      // Storage unavailable: keep defaults for this session.
    }
    notifyListeners();
  }

  set cameraInputType(String value) =>
      _update(() => _cameraInputType = value, 'cameraInputType', value);
  set cameraGridByDefault(bool value) =>
      _update(() => _cameraGridByDefault = value, 'cameraGridByDefault', value);
  set resultFilter(String value) =>
      _update(() => _resultFilter = value, 'resultFilter', value);
  set showBoundingBoxesByDefault(bool value) => _update(
    () => _showBoundingBoxesByDefault = value,
    'showBoundingBoxesByDefault',
    value,
  );
  set minConfidence(double value) =>
      _update(() => _minConfidence = value, 'minConfidence', value);
  set hapticsEnabled(bool value) =>
      _update(() => _hapticsEnabled = value, 'hapticsEnabled', value);
  set reduceTransparency(bool value) =>
      _update(() => _reduceTransparency = value, 'reduceTransparency', value);

  Future<void> resetToDefaults() async {
    _cameraInputType = defaultCameraInputType;
    _cameraGridByDefault = false;
    _resultFilter = defaultResultFilter;
    _showBoundingBoxesByDefault = false;
    _minConfidence = defaultMinConfidence;
    _hapticsEnabled = true;
    _reduceTransparency = false;
    notifyListeners();
    try {
      await _prefs?.clear();
      // Not a preference: resetting settings shouldn't replay the intro.
      if (_hasSeenIntro) await _prefs?.setBool('hasSeenIntro', true);
    } catch (_) {}
  }

  void _update(VoidCallback apply, String key, Object value) {
    apply();
    notifyListeners();
    final prefs = _prefs;
    if (prefs == null) return;
    switch (value) {
      case String v:
        prefs.setString(key, v);
      case bool v:
        prefs.setBool(key, v);
      case double v:
        prefs.setDouble(key, v);
    }
  }
}
