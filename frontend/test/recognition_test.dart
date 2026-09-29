// White-box tests for how the app reads recognizer replies.
//
// ERROR HANDLING: every failure the Python bridge can produce (crash,
// timeout, null / malformed / non-object JSON, 'error' replies, empty
// input) must come back as null - never an exception - and every reply
// must map to exactly one RecognitionOutcome.
//
// STATEMENT COVERAGE: each branch of OfflineRecognizer, RecognitionOutcome,
// scannedDetections, isValidBox and readNumber is hit at least once.
import 'dart:async';
import 'dart:convert';

import 'package:dayaw/services/offline_recognizer.dart';
import 'package:dayaw/services/recognition_outcome.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final image = Uint8List.fromList([1, 2, 3]);

  /// Makes the fake Python side answer [reply] (or run [handler]).
  void pythonReplies(Future<Object?> Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(OfflineRecognizer.channel, handler);
  }

  tearDown(() {
    messenger.setMockMethodCallHandler(OfflineRecognizer.channel, null);
    OfflineRecognizer.timeout = const Duration(seconds: 60);
  });

  group('OfflineRecognizer.recognize - error handling', () {
    test('valid JSON object is returned as a map', () async {
      pythonReplies((call) async {
        expect(call.method, 'recognize');
        expect(call.arguments['inputType'], 'pen');
        return jsonEncode({'status': 'Success', 'translated_text': 'bata'});
      });
      final reply = await OfflineRecognizer.recognize(image, inputType: 'pen');
      expect(reply, {'status': 'Success', 'translated_text': 'bata'});
    });

    test('empty image is rejected without calling Python', () async {
      var called = false;
      pythonReplies((_) async => called = true);
      expect(
        await OfflineRecognizer.recognize(Uint8List(0), inputType: 'marker'),
        isNull,
      );
      expect(called, isFalse);
    });

    test('null reply -> null', () async {
      pythonReplies((_) async => null);
      expect(
        await OfflineRecognizer.recognize(image, inputType: 'marker'),
        isNull,
      );
    });

    test('empty string reply -> null', () async {
      pythonReplies((_) async => '');
      expect(
        await OfflineRecognizer.recognize(image, inputType: 'marker'),
        isNull,
      );
    });

    test('malformed JSON -> null (FormatException caught)', () async {
      pythonReplies((_) async => '{not json');
      expect(
        await OfflineRecognizer.recognize(image, inputType: 'marker'),
        isNull,
      );
    });

    test('JSON that is not an object -> null', () async {
      pythonReplies((_) async => '[1, 2, 3]');
      expect(
        await OfflineRecognizer.recognize(image, inputType: 'marker'),
        isNull,
      );
    });

    test("reply carrying 'error' -> null", () async {
      pythonReplies(
        (_) async => jsonEncode({'error': 'boom', 'status': 'Error'}),
      );
      expect(
        await OfflineRecognizer.recognize(image, inputType: 'marker'),
        isNull,
      );
    });

    test('PlatformException from the plugin -> null', () async {
      pythonReplies((_) async => throw PlatformException(code: 'PY_CRASH'));
      expect(
        await OfflineRecognizer.recognize(image, inputType: 'marker'),
        isNull,
      );
    });

    test('missing plugin -> null', () async {
      // No handler registered at all.
      expect(
        await OfflineRecognizer.recognize(image, inputType: 'marker'),
        isNull,
      );
    });

    test('a call that never answers times out -> null', () async {
      OfflineRecognizer.timeout = const Duration(milliseconds: 50);
      pythonReplies((_) => Completer<Object?>().future); // never completes
      expect(
        await OfflineRecognizer.recognize(image, inputType: 'marker'),
        isNull,
      );
    });
  });

  group('OfflineRecognizer - other calls', () {
    test('warmUp swallows failures', () async {
      pythonReplies((_) async => throw PlatformException(code: 'X'));
      await expectLater(OfflineRecognizer.warmUp(), completes);
    });

    test('warmUp succeeds', () async {
      pythonReplies((_) async => 'ok');
      await expectLater(OfflineRecognizer.warmUp(), completes);
    });

    test('translateText returns the map, or null on error', () async {
      pythonReplies((call) async => jsonEncode({'translated_text': 'ᜊ'}));
      expect(await OfflineRecognizer.translateText('ba'), {
        'translated_text': 'ᜊ',
      });
      pythonReplies((_) async => throw PlatformException(code: 'X'));
      expect(await OfflineRecognizer.translateText('ba'), isNull);
    });
  });

  group('RecognitionOutcome.of - one outcome per reply', () {
    final cases = <Map<String, dynamic>?, RecognitionOutcome>{
      null: RecognitionOutcome.failed,
      {'error': 'x'}: RecognitionOutcome.failed,
      {'status': 'Success'}: RecognitionOutcome.success,
      {'status': 'success'}: RecognitionOutcome.success,
      {'status': 'Low_Confidence'}: RecognitionOutcome.lowConfidence,
      {'status': 'No_Characters'}: RecognitionOutcome.noCharacters,
      {'status': 'Blurry_Image'}: RecognitionOutcome.blurry,
      {'status': 'Invalid_Image'}: RecognitionOutcome.invalidImage,
      {'status': 'Something_New'}: RecognitionOutcome.failed,
      {}: RecognitionOutcome.failed,
      {'status': 42}: RecognitionOutcome.failed,
    };
    cases.forEach((reply, expected) {
      test('$reply -> ${expected.name}', () {
        expect(RecognitionOutcome.of(reply), expected);
      });
    });

    test('only success and lowConfidence carry text', () {
      expect(RecognitionOutcome.values.where((o) => o.hasText), [
        RecognitionOutcome.success,
        RecognitionOutcome.lowConfidence,
      ]);
    });
  });

  group('scannedDetections - sanitizing', () {
    test('missing or non-list detections -> empty', () {
      expect(scannedDetections(null), isEmpty);
      expect(scannedDetections({}), isEmpty);
      expect(scannedDetections({'individual_detections': 'nope'}), isEmpty);
    });

    test('non-map entries are dropped, good ones kept', () {
      final list = scannedDetections({
        'individual_detections': [
          'junk',
          7,
          {
            'char': 'ba',
            'confidence': 91.5,
            'bbox': {'x0': 1, 'y0': 2, 'x1': 10, 'y1': 20},
          },
        ],
      });
      expect(list, hasLength(1));
      expect(list.single['char'], 'ba');
      expect(list.single['confidence'], 91.5);
      expect(list.single['bbox'], {'x0': 1, 'y0': 2, 'x1': 10, 'y1': 20});
    });

    test('bad bbox is removed and bad confidence becomes 0', () {
      final d = scannedDetections({
        'individual_detections': [
          {
            'char': 'ka',
            'confidence': 'high',
            'bbox': {'x0': 5, 'y0': 5, 'x1': 'x', 'y1': 9},
          },
        ],
      }).single;
      expect(d['bbox'], isNull);
      expect(d['confidence'], 0.0);
      expect(d['char'], 'ka');
    });
  });

  group('isValidBox', () {
    test('accepts an ordered box of finite numbers', () {
      expect(isValidBox({'x0': 0, 'y0': 0, 'x1': 1.5, 'y1': 2}), isTrue);
    });
    test('rejects non-maps, missing keys, non-numbers, infinities', () {
      expect(isValidBox(null), isFalse);
      expect(isValidBox([0, 0, 1, 1]), isFalse);
      expect(isValidBox({'x0': 0, 'y0': 0, 'x1': 1}), isFalse);
      expect(isValidBox({'x0': '0', 'y0': 0, 'x1': 1, 'y1': 1}), isFalse);
      expect(
        isValidBox({'x0': 0, 'y0': 0, 'x1': double.infinity, 'y1': 1}),
        isFalse,
      );
    });
    test('rejects empty or inverted boxes', () {
      expect(isValidBox({'x0': 5, 'y0': 0, 'x1': 5, 'y1': 1}), isFalse);
      expect(isValidBox({'x0': 0, 'y0': 9, 'x1': 5, 'y1': 1}), isFalse);
    });
  });

  group('readNumber', () {
    test('numbers, numeric strings and fallbacks', () {
      expect(readNumber({'a': 3}, 'a'), 3.0);
      expect(readNumber({'a': 2.5}, 'a'), 2.5);
      expect(readNumber({'a': '7.25'}, 'a'), 7.25);
      expect(readNumber({'a': 'seven'}, 'a'), 0.0);
      expect(readNumber({'a': null}, 'a', fallback: -1), -1.0);
      expect(readNumber({'a': double.nan}, 'a', fallback: 4), 4.0);
      expect(readNumber({'a': true}, 'a'), 0.0);
      expect(readNumber(null, 'a'), 0.0);
    });
  });
}
