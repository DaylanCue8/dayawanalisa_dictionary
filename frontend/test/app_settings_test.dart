// White-box tests for AppSettings.
//
// ERROR HANDLING: stored values that are missing, of the wrong type or
// out of range must fall back to defaults one setting at a time, and bad
// values passed to setters must be corrected, never stored.
// STATEMENT COVERAGE: load, every setter, reset and the validators.
import 'package:dayaw/services/app_settings.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

/// A device storage that fails every read and write.
class _BrokenStore extends SharedPreferencesStorePlatform {
  Never _fail() => throw Exception('storage unavailable');
  @override
  Future<Map<String, Object>> getAll() async => _fail();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      _fail();
  @override
  Future<bool> remove(String key) async => _fail();
  @override
  Future<bool> clear() async => _fail();
}

Future<(AppSettings, SharedPreferences)> loadWith(
  Map<String, Object> stored,
) async {
  SharedPreferences.resetStatic();
  SharedPreferences.setMockInitialValues(stored);
  final settings = AppSettings.forTesting();
  await settings.load();
  return (settings, await SharedPreferences.getInstance());
}

/// Lets the fire-and-forget save in the setters finish.
Future<void> flushSaves() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('load', () {
    test('empty storage gives the defaults', () async {
      final (s, _) = await loadWith({});
      expect(s.cameraInputType, AppSettings.defaultCameraInputType);
      expect(s.resultFilter, AppSettings.defaultResultFilter);
      expect(s.minConfidence, AppSettings.defaultMinConfidence);
      expect(s.language, 'en');
      expect(s.hapticsEnabled, isTrue);
      expect(s.reduceTransparency, isFalse);
      expect(s.cameraGridByDefault, isFalse);
      expect(s.showBoundingBoxesByDefault, isFalse);
      expect(s.hasSeenIntro, isFalse);
    });

    test('valid stored values are loaded', () async {
      final (s, _) = await loadWith({
        'cameraInputType': 'pen',
        'resultFilter': 'Raw',
        'minConfidence': 50.0,
        'language': 'fil',
        'hapticsEnabled': false,
        'reduceTransparency': true,
        'cameraGridByDefault': true,
        'showBoundingBoxesByDefault': true,
        'hasSeenIntro': true,
      });
      expect(s.cameraInputType, 'pen');
      expect(s.resultFilter, 'Raw');
      expect(s.minConfidence, 50.0);
      expect(s.language, 'fil');
      expect(s.hapticsEnabled, isFalse);
      expect(s.reduceTransparency, isTrue);
      expect(s.cameraGridByDefault, isTrue);
      expect(s.showBoundingBoxesByDefault, isTrue);
      expect(s.hasSeenIntro, isTrue);
    });

    test('unknown values fall back to defaults', () async {
      final (s, _) = await loadWith({
        'cameraInputType': 'crayon',
        'resultFilter': 'Sepia',
        'language': 'jp',
      });
      expect(s.cameraInputType, 'marker');
      expect(s.resultFilter, 'HOG');
      expect(s.language, 'en');
    });

    test('out-of-range confidence is clamped', () async {
      expect((await loadWith({'minConfidence': 500.0})).$1.minConfidence, 90.0);
      expect((await loadWith({'minConfidence': -3.0})).$1.minConfidence, 0.0);
    });

    test('wrongly-typed values only reset that one setting', () async {
      final (s, _) = await loadWith({
        'minConfidence': 'high', // should be a double
        'hapticsEnabled': 'yes', // should be a bool
        'language': 'fil', // valid - must survive
      });
      expect(s.minConfidence, AppSettings.defaultMinConfidence);
      expect(s.hapticsEnabled, isTrue);
      expect(s.language, 'fil');
    });
  });

  group('setters validate and save', () {
    test('valid values are applied and saved', () async {
      final (s, prefs) = await loadWith({});
      s.cameraInputType = 'pen';
      s.resultFilter = 'Black and White';
      s.minConfidence = 40;
      s.language = 'fil';
      s.hapticsEnabled = false;
      s.reduceTransparency = true;
      s.cameraGridByDefault = true;
      s.showBoundingBoxesByDefault = true;
      s.hasSeenIntro = true;
      await flushSaves();
      expect(prefs.getString('cameraInputType'), 'pen');
      expect(prefs.getString('resultFilter'), 'Black and White');
      expect(prefs.getDouble('minConfidence'), 40);
      expect(prefs.getString('language'), 'fil');
      expect(prefs.getBool('hapticsEnabled'), isFalse);
      expect(prefs.getBool('reduceTransparency'), isTrue);
      expect(prefs.getBool('cameraGridByDefault'), isTrue);
      expect(prefs.getBool('showBoundingBoxesByDefault'), isTrue);
      expect(prefs.getBool('hasSeenIntro'), isTrue);
    });

    test('invalid values are corrected, not stored as-is', () async {
      final (s, prefs) = await loadWith({});
      s.cameraInputType = 'crayon';
      s.resultFilter = '';
      s.minConfidence = double.nan;
      s.language = 'xx';
      await flushSaves();
      expect(s.cameraInputType, 'marker');
      expect(s.resultFilter, 'HOG');
      expect(s.minConfidence, AppSettings.defaultMinConfidence);
      expect(s.language, 'en');
      expect(prefs.getString('language'), 'en');
    });

    test('setters notify listeners', () async {
      final (s, _) = await loadWith({});
      var calls = 0;
      s.addListener(() => calls++);
      s.hapticsEnabled = false;
      s.minConfidence = 10;
      expect(calls, 2);
    });

    test('setting before load (no storage yet) does not throw', () {
      final s = AppSettings.forTesting();
      expect(() => s.minConfidence = 30, returnsNormally);
      expect(s.minConfidence, 30);
    });
  });

  group('resetToDefaults', () {
    test('restores defaults but keeps language and intro flag', () async {
      final (s, prefs) = await loadWith({
        'cameraInputType': 'pen',
        'minConfidence': 70.0,
        'language': 'fil',
        'hasSeenIntro': true,
        'hapticsEnabled': false,
      });
      await s.resetToDefaults();
      expect(s.cameraInputType, 'marker');
      expect(s.minConfidence, AppSettings.defaultMinConfidence);
      expect(s.hapticsEnabled, isTrue);
      expect(s.language, 'fil');
      expect(prefs.getString('language'), 'fil');
      expect(prefs.getBool('hasSeenIntro'), isTrue);
      expect(prefs.getString('cameraInputType'), isNull);
    });
  });

  group('storage failures never crash the app', () {
    late SharedPreferencesStorePlatform realStore;
    setUp(() => realStore = SharedPreferencesStorePlatform.instance);
    tearDown(() => SharedPreferencesStorePlatform.instance = realStore);

    test('unreadable storage -> defaults for this session', () async {
      SharedPreferences.resetStatic();
      SharedPreferencesStorePlatform.instance = _BrokenStore();
      final s = AppSettings.forTesting();
      await expectLater(s.load(), completes);
      expect(s.language, 'en');
      expect(s.minConfidence, AppSettings.defaultMinConfidence);
    });

    test('a failed save keeps the new value in memory', () async {
      final (s, _) = await loadWith({});
      SharedPreferencesStorePlatform.instance = _BrokenStore();
      s.hapticsEnabled = false;
      await flushSaves();
      expect(s.hapticsEnabled, isFalse);
    });

    test('a failed reset still restores defaults in memory', () async {
      final (s, _) = await loadWith({'cameraInputType': 'pen'});
      SharedPreferencesStorePlatform.instance = _BrokenStore();
      await expectLater(s.resetToDefaults(), completes);
      expect(s.cameraInputType, 'marker');
    });
  });

  group('validators', () {
    test('oneOf', () {
      expect(
        AppSettings.oneOf('pen', AppSettings.cameraInputTypes, 'marker'),
        'pen',
      );
      expect(
        AppSettings.oneOf('PEN', AppSettings.cameraInputTypes, 'marker'),
        'marker',
      );
      expect(
        AppSettings.oneOf(null, AppSettings.cameraInputTypes, 'marker'),
        'marker',
      );
    });

    test('validConfidence', () {
      expect(AppSettings.validConfidence(45), 45);
      expect(AppSettings.validConfidence(91), 90);
      expect(AppSettings.validConfidence(-1), 0);
      expect(
        AppSettings.validConfidence(null),
        AppSettings.defaultMinConfidence,
      );
      expect(
        AppSettings.validConfidence(double.infinity),
        AppSettings.defaultMinConfidence,
      );
    });
  });
}
