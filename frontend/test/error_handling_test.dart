// test/error_handling_test.dart
//
// WHITE BOX TESTING - ERROR HANDLING (Dart side of Dayaw)
//
// Run:   flutter test test/error_handling_test.dart --reporter expanded
//
// 1. FTB engine (TagalogToBaybayinLocalTranslator): unusual and extreme
//    text input must never throw, and must always return a String
//    translation and a confidence between 0 and 100.
// 2. OfflineRecognizer (the bridge from Flutter to the Python recognizer):
//    its contract says it NEVER throws - every failure (empty image,
//    plugin error, Python error, timeout, null or malformed reply) must
//    come back as null so the app shows "failed" instead of crashing.
//    The Python side is replaced here by a mock MethodChannel, so each
//    failure can be produced on purpose.
//
// Adjust the two imports below if your files are in a different folder.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:dayaw/services/tagalog_to_baybayin_local_translator.dart';
import 'package:dayaw/services/offline_recognizer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // =====================================================================
  // A. FILIPINO-TO-BAYBAYIN ENGINE
  // =====================================================================
  group('FTB error handling', () {
    final translator = TagalogToBaybayinLocalTranslator();

    // Every case: translate() must not throw, and must return a usable map.
    void expectHandled(String input) {
      late Map result;
      expect(() => result = translator.translate(input), returnsNormally,
          reason: 'translate() threw for input: "$input"');
      expect(result['translated_text'], isA<String>());
      final conf = (result['confidence'] as num).toDouble();
      expect(conf, inInclusiveRange(0, 100));
    }

    test('FTB-01 empty input', () {
      expectHandled('');
      expect(translator.translate('')['translated_text'], '');
    });

    test('FTB-02 spaces, tabs and new lines only', () {
      expectHandled('   \t \n  ');
    });

    test('FTB-03 numbers only', () => expectHandled('1234567890'));

    test('FTB-04 symbols only', () => expectHandled(r'@#$%^&*()_+=[]{}<>/\|~`'));

    test('FTB-05 letters mixed with numbers and symbols',
        () => expectHandled('ba2hay! ka#main? 3 araw'));

    test('FTB-06 letters outside B17+ (c f j q v x z)',
        () => expectHandled('cafe fiesta jeep quiz video taxi zoo'));

    test('FTB-07 accented letters and n-tilde',
        () => expectHandled('Señor niño pagbasá doón'));

    test('FTB-08 emoji', () => expectHandled('salamat 😊👍'));

    test('FTB-09 text that is already Baybayin', () => expectHandled('ᜊᜑᜌ᜔'));

    test('FTB-10 other writing systems', () => expectHandled('你好 привет مرحبا'));

    test('FTB-11 a single consonant', () => expectHandled('k'));

    test('FTB-12 consonant clusters', () => expectHandled('strng tsk brrr ngng'));

    test('FTB-13 repeated punctuation', () => expectHandled('...,,,!!!???'));

    test('FTB-14 very long input (about 10,000 characters)', () {
      final long = List.filled(1000, 'kumain ').join();
      final sw = Stopwatch()..start();
      expectHandled(long);
      sw.stop();
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)),
          reason: 'a long text must not freeze the app');
    });

    test('FTB-15 same unusual input twice gives the same output', () {
      const odd = 'Fé 123 ng-mga!!';
      expect(translator.translate(odd)['translated_text'],
          translator.translate(odd)['translated_text']);
    });
  });

  // =====================================================================
  // B. OFFLINE RECOGNIZER (Flutter <-> Python bridge)
  // =====================================================================
  group('OfflineRecognizer error handling', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final image = Uint8List.fromList(List.filled(100, 7));
    var calls = 0;

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

    test('REC-11 FTB text mode: Python error returns null', () async {
      mockReply((_) async => throw PlatformException(code: 'PYTHON_ERROR'));
      expect(await OfflineRecognizer.translateText('bahay'), isNull);
    });

    test('REC-12 warm-up failure does not throw', () async {
      mockReply((_) async => throw PlatformException(code: 'PYTHON_ERROR'));
      await expectLater(OfflineRecognizer.warmUp(), completes);
    });
  });
}