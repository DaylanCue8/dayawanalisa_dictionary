import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// App-wide user preferences, saved on the device so they survive
/// restarts. Screens read [AppSettings.instance]; widgets that must react
/// to a change (e.g. the glass look) listen to it.
///
/// Error handling: every value is validated both when it's loaded and
/// when it's set. A missing, wrongly-typed or out-of-range stored value
/// (old app version, corrupted storage) falls back to its default for
/// that one setting only, and storage failures never crash the app.
class AppSettings extends ChangeNotifier {
  AppSettings._();
  static final AppSettings instance = AppSettings._();

  /// A fresh, independent instance for unit tests.
  @visibleForTesting
  factory AppSettings.forTesting() => AppSettings._();

  static const defaultCameraInputType = 'marker';
  static const defaultResultFilter = 'HOG';
  static const defaultMinConfidence = 23.0;
  static const defaultLanguage = 'en';

  /// Accepted values, used to validate loaded and set values.
  static const cameraInputTypes = ['marker', 'pen'];
  static const resultFilters = ['Raw', 'Black and White', 'HOG'];
  static const languages = ['en', 'fil'];
  static const minConfidenceRange = (min: 0.0, max: 90.0);

  SharedPreferences? _prefs;

  String _cameraInputType = defaultCameraInputType;
  bool _cameraGridByDefault = false;
  String _resultFilter = defaultResultFilter;
  bool _showBoundingBoxesByDefault = false;
  double _minConfidence = defaultMinConfidence;
  bool _hapticsEnabled = true;
  bool _reduceTransparency = false;
  bool _hasSeenIntro = false;

  /// App language: 'en' (English) or 'fil' (Filipino). Kept in its own
  /// notifier so a language change rebuilds exactly the widgets that show
  /// text (see LanguageScope), not everything that listens to settings.
  final ValueNotifier<String> languageNotifier = ValueNotifier(defaultLanguage);
  String get language => languageNotifier.value;
  set language(String value) {
    final valid = _oneOf(value, languages, defaultLanguage);
    languageNotifier.value = valid;
    _update(() {}, 'language', valid);
  }

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

  /// Detections below this confidence (0-90) are left out of the
  /// Character Breakdown and the bounding boxes.
  double get minConfidence => _minConfidence;
  bool get hapticsEnabled => _hapticsEnabled;

  /// Swaps the frosted glass blur for solid panels: easier to read and
  /// lighter on slower phones.
  bool get reduceTransparency => _reduceTransparency;

  Future<void> load() async {
    final SharedPreferences prefs;
    try {
      prefs = _prefs = await SharedPreferences.getInstance();
    } catch (e) {
      // Storage unavailable: keep defaults for this session.
      debugPrint('[SETTINGS] storage unavailable: $e');
      notifyListeners();
      return;
    }
    _cameraInputType = _oneOf(
      _read(() => prefs.getString('cameraInputType')),
      cameraInputTypes,
      defaultCameraInputType,
    );
    _cameraGridByDefault =
        _read(() => prefs.getBool('cameraGridByDefault')) ?? false;
    _resultFilter = _oneOf(
      _read(() => prefs.getString('resultFilter')),
      resultFilters,
      defaultResultFilter,
    );
    _showBoundingBoxesByDefault =
        _read(() => prefs.getBool('showBoundingBoxesByDefault')) ?? false;
    _minConfidence = _confidence(_read(() => prefs.getDouble('minConfidence')));
    _hapticsEnabled = _read(() => prefs.getBool('hapticsEnabled')) ?? true;
    _reduceTransparency =
        _read(() => prefs.getBool('reduceTransparency')) ?? false;
    _hasSeenIntro = _read(() => prefs.getBool('hasSeenIntro')) ?? false;
    languageNotifier.value = _oneOf(
      _read(() => prefs.getString('language')),
      languages,
      defaultLanguage,
    );
    notifyListeners();
  }

  set cameraInputType(String value) {
    final valid = _oneOf(value, cameraInputTypes, defaultCameraInputType);
    _update(() => _cameraInputType = valid, 'cameraInputType', valid);
  }

  set cameraGridByDefault(bool value) =>
      _update(() => _cameraGridByDefault = value, 'cameraGridByDefault', value);

  set resultFilter(String value) {
    final valid = _oneOf(value, resultFilters, defaultResultFilter);
    _update(() => _resultFilter = valid, 'resultFilter', valid);
  }

  set showBoundingBoxesByDefault(bool value) => _update(
    () => _showBoundingBoxesByDefault = value,
    'showBoundingBoxesByDefault',
    value,
  );

  set minConfidence(double value) {
    final valid = _confidence(value);
    _update(() => _minConfidence = valid, 'minConfidence', valid);
  }

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
      // Language is kept too - resetting shouldn't switch the whole app
      // into a language the person may not read.
      await _prefs?.setString('language', language);
    } catch (e) {
      debugPrint('[SETTINGS] reset could not clear storage: $e');
    }
  }

  // ---- validation helpers (static, so they're easy to unit test) ----

  /// [value] if it's one of [allowed], otherwise [fallback].
  @visibleForTesting
  static String oneOf(String? value, List<String> allowed, String fallback) =>
      _oneOf(value, allowed, fallback);

  /// A finite confidence clamped to [minConfidenceRange], or the default.
  @visibleForTesting
  static double validConfidence(double? value) => _confidence(value);

  static String _oneOf(String? value, List<String> allowed, String fallback) =>
      value != null && allowed.contains(value) ? value : fallback;

  static double _confidence(double? value) {
    if (value == null || !value.isFinite) return defaultMinConfidence;
    return value
        .clamp(minConfidenceRange.min, minConfidenceRange.max)
        .toDouble();
  }

  /// Reads one stored value; a wrongly-typed entry reads as null (so that
  /// setting falls back to its default) instead of throwing.
  static T? _read<T>(T? Function() read) {
    try {
      return read();
    } catch (e) {
      debugPrint('[SETTINGS] ignoring unreadable stored value: $e');
      return null;
    }
  }

  void _update(VoidCallback apply, String key, Object value) {
    apply();
    notifyListeners();
    final prefs = _prefs;
    if (prefs == null) return;
    // Saving is fire-and-forget; a failed write only means the change
    // won't survive a restart, so it must never crash the app.
    Future<void>(() async {
      switch (value) {
        case String v:
          await prefs.setString(key, v);
        case bool v:
          await prefs.setBool(key, v);
        case double v:
          await prefs.setDouble(key, v);
      }
    }).catchError((Object e) {
      debugPrint('[SETTINGS] could not save "$key": $e');
    });
  }
}
