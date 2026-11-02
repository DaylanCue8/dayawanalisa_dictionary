// test/error_handling_test.dart
//
// WHITE BOX TESTING - ERROR HANDLING (Dart side of Dayaw)
//
// Run:   flutter test test/error_handling_test.dart --reporter expanded
//        (the WB-03 / WB-04 times are printed after each group)
//
// OfflineRecognizer (the bridge from Flutter to the Python recognizer):
//    its contract says it NEVER throws - every failure (empty image,
//    plugin error, Python error, timeout, null or malformed reply) must
//    come back as null so the app shows "failed" instead of crashing.
//    The Python side is replaced here by a mock MethodChannel, so each
//    failure can be produced on purpose.
//    Both directions are tested: recognize (Baybayin to Latin, REC-01..11)
//    and recognizeLatin (Latin to Baybayin, LTB-REC-01..11).
//
// Adjust the import below if your files are in a different folder.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dayaw/services/offline_recognizer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // =====================================================================
  // OFFLINE RECOGNIZER (Flutter <-> Python bridge)
  // =====================================================================
  group('OfflineRecognizer error handling', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final image = Uint8List.fromList(List.filled(100, 7));
    var calls = 0;

    // ---- timing for the white box summary table (WB-03) ----
    final sw = Stopwatch();
    setUpAll(() => sw.start());
    tearDownAll(() {
      sw.stop();
      print('WB-03 Baybayin-to-Latin connection (REC-01..REC-11): '
          '${sw.elapsedMilliseconds} ms');
    });

    void mockReply(Future<Object?>? Function(MethodCall call) handler) {
      messenger.setMockMethodCallHandler(OfflineRecognizer.channel, (call) {
        calls++;
        return handler(call);
      });
    }

    setUp(() {
      calls = 0;
      OfflineRecognizer.timeout = const Duration(seconds: 2);
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(OfflineRecognizer.channel, null);
    });

    test('REC-01 empty image is rejected before calling Python', () async {
      mockReply((_) async => '{"translated_text":"ba"}');
      final result = await OfflineRecognizer.recognize(Uint8List(0), inputType: 'pen');
      expect(result, isNull);
      expect(calls, 0);
    });

    test('REC-02 Python returns null', () async {
      mockReply((_) async => null);
      expect(await OfflineRecognizer.recognize(image, inputType: 'pen'), isNull);
    });

    test('REC-03 Python returns an empty string', () async {
      mockReply((_) async => '');
      expect(await OfflineRecognizer.recognize(image, inputType: 'pen'), isNull);
    });

    test('REC-04 Python returns malformed JSON', () async {
      mockReply((_) async => '{"translated_text": "ba"');
      expect(await OfflineRecognizer.recognize(image, inputType: 'pen'), isNull);
    });

    test('REC-05 Python returns JSON that is not an object', () async {
      mockReply((_) async => '["ba", "ka"]');
      expect(await OfflineRecognizer.recognize(image, inputType: 'pen'), isNull);
    });

    test('REC-06 Python reports an error', () async {
      mockReply((_) async => '{"error": "cannot decode image", "status": "Error"}');
      expect(await OfflineRecognizer.recognize(image, inputType: 'pen'), isNull);
    });

    test('REC-07 platform exception from the Android side', () async {
      mockReply((_) async => throw PlatformException(code: 'PYTHON_ERROR'));
      expect(await OfflineRecognizer.recognize(image, inputType: 'pen'), isNull);
    });

    test('REC-08 recognizer not available (missing plugin)', () async {
      mockReply((_) async => throw MissingPluginException());
      expect(await OfflineRecognizer.recognize(image, inputType: 'pen'), isNull);
    });

    test('REC-09 recognizer takes too long (timeout)', () async {
      OfflineRecognizer.timeout = const Duration(milliseconds: 200);
      mockReply((_) => Future.delayed(const Duration(seconds: 1), () => '{}'));
      expect(await OfflineRecognizer.recognize(image, inputType: 'pen'), isNull);
    });

    test('REC-10 a valid reply is passed through (control)', () async {
      mockReply((_) async =>
          '{"translated_text": "bahay", "confidence": 95.0, "status": "Success"}');
      final result = await OfflineRecognizer.recognize(image, inputType: 'pen');
      expect(result, isNotNull);
      expect(result!['translated_text'], 'bahay');
    });

    test('REC-11 warm-up failure does not throw', () async {
      mockReply((_) async => throw PlatformException(code: 'PYTHON_ERROR'));
      await expectLater(OfflineRecognizer.warmUp(), completes);
    });
  });

  // =====================================================================
  // LATIN TO BAYBAYIN: same bridge, recognizeLatin (pen / marker)
  // =====================================================================
  group('OfflineRecognizer.recognizeLatin error handling', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final image = Uint8List.fromList(List.filled(100, 7));
    var calls = 0;
    MethodCall? lastCall;

    // ---- timing for the white box summary table (WB-04) ----
    final sw = Stopwatch();
    setUpAll(() => sw.start());
    tearDownAll(() {
      sw.stop();
      print('WB-04 Latin-to-Baybayin connection (LTB-REC-01..LTB-REC-11): '
          '${sw.elapsedMilliseconds} ms');
    });

    void mockReply(Future<Object?>? Function(MethodCall call) handler) {
      messenger.setMockMethodCallHandler(OfflineRecognizer.channel, (call) {
        calls++;
        lastCall = call;
        return handler(call);
      });
    }

    setUp(() {
      calls = 0;
      lastCall = null;
      OfflineRecognizer.timeout = const Duration(seconds: 2);
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(OfflineRecognizer.channel, null);
    });

    test('LTB-REC-01 empty image is rejected before calling Python', () async {
      mockReply((_) async => '{"baybayin_text":"\u170a"}');
      final result = await OfflineRecognizer.recognizeLatin(Uint8List(0));
      expect(result, isNull);
      expect(calls, 0);
    });

    test('LTB-REC-02 Python returns null', () async {
      mockReply((_) async => null);
      expect(await OfflineRecognizer.recognizeLatin(image), isNull);
    });

    test('LTB-REC-03 Python returns an empty string', () async {
      mockReply((_) async => '');
      expect(await OfflineRecognizer.recognizeLatin(image), isNull);
    });

    test('LTB-REC-04 Python returns malformed JSON', () async {
      mockReply((_) async => '{"latin_text": "bahay"');
      expect(await OfflineRecognizer.recognizeLatin(image), isNull);
    });

    test('LTB-REC-05 Python returns JSON that is not an object', () async {
      mockReply((_) async => '["ba", "hay"]');
      expect(await OfflineRecognizer.recognizeLatin(image), isNull);
    });

    test('LTB-REC-06 Python reports an error', () async {
      mockReply((_) async => '{"error": "cannot decode image", "status": "Error"}');
      expect(await OfflineRecognizer.recognizeLatin(image), isNull);
    });

    test('LTB-REC-07 platform exception from the Android side', () async {
      mockReply((_) async => throw PlatformException(code: 'PYTHON_ERROR'));
      expect(await OfflineRecognizer.recognizeLatin(image), isNull);
    });

    test('LTB-REC-08 recognizer not available (missing plugin)', () async {
      mockReply((_) async => throw MissingPluginException());
      expect(await OfflineRecognizer.recognizeLatin(image), isNull);
    });

    test('LTB-REC-09 recognizer takes too long (timeout)', () async {
      OfflineRecognizer.timeout = const Duration(milliseconds: 200);
      mockReply((_) => Future.delayed(const Duration(seconds: 1), () => '{}'));
      expect(await OfflineRecognizer.recognizeLatin(image), isNull);
    });

    test('LTB-REC-10 a valid reply is passed through (control)', () async {
      mockReply((_) async =>
          '{"latin_text": "bahay", "baybayin_text": "\u170a\u1711\u170c\u1714", '
          '"confidence": 95.0, "status": "Success"}');
      final result = await OfflineRecognizer.recognizeLatin(image);
      expect(result, isNotNull);
      expect(result!['latin_text'], 'bahay');
    });

    test('LTB-REC-11 the Pen / Marker choice reaches Python', () async {
      mockReply((_) async => '{"latin_text": "ama", "status": "Success"}');
      await OfflineRecognizer.recognizeLatin(image, inputType: 'marker');
      expect(lastCall?.method, 'recognizeLatin');
      expect((lastCall?.arguments as Map)['inputType'], 'marker');
      await OfflineRecognizer.recognizeLatin(image);
      expect((lastCall?.arguments as Map)['inputType'], 'pen');
    });
  });
}