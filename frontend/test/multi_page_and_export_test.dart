// White-box tests for multi-page results and exports.
//
// ERROR HANDLING: unread / malformed pages never break the combined
// result; a broken image makes export fail with an exception the result
// screen catches (not a silent bad file).
// STATEMENT COVERAGE: ScannedPage, averageConfidence, combinedText /
// combinedConfidence, ResultExporter.buildText (both languages) and
// buildPdf (A4 and single tall page).
import 'dart:convert';
import 'dart:typed_data';

import 'package:dayaw/screens/multi_page_result_screen.dart';
import 'package:dayaw/services/app_settings.dart';
import 'package:dayaw/services/result_exporter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:printing/printing.dart' show PdfRaster;
import 'package:share_plus/share_plus.dart' show ShareParams;

Map<String, dynamic> reply(String status, String text, List<double> confs) => {
  'status': status,
  'translated_text': text,
  'individual_detections': [
    for (final c in confs)
      {
        'char': 'x',
        'confidence': c,
        'bbox': {'x0': 0, 'y0': 0, 'x1': 5, 'y1': 5},
      },
  ],
};

final Uint8List png = Uint8List.fromList(
  img.encodePng(img.Image(width: 40, height: 20)),
);

ResultExport sampleExport({
  Uint8List? image,
  List<ExportBox> boxes = const [],
}) => ResultExport(
  filteredImage: image ?? png,
  filter: 'HOG',
  imageWidth: 40,
  imageHeight: 20,
  boxes: boxes,
  translatedText: 'mahal kita',
  averageConfidence: 88.4,
  characterCount: 5,
  lines: [
    [ExportCharacter(png, 'ma', 95), ExportCharacter(png, 'ha', 80)],
    [ExportCharacter(png, 'ki', 70)],
  ],
  createdAt: DateTime(2026, 9, 29, 14, 5),
);

void main() {
  group('ScannedPage', () {
    test('a successful page is read, with its text and confidence', () {
      final page = ScannedPage(png, reply('Success', 'bata', [90, 70]));
      expect(page.isRead, isTrue);
      expect(page.text, 'bata');
      expect(page.detections, hasLength(2));
      expect(page.confidence, 80);
    });

    test('low confidence still counts as read', () {
      expect(
        ScannedPage(png, reply('Low_Confidence', 'ba', [40])).isRead,
        isTrue,
      );
    });

    test('failed, blurry, empty-text and null pages are not read', () {
      expect(ScannedPage(png, null).isRead, isFalse);
      expect(ScannedPage(png, reply('Blurry_Image', '', [])).isRead, isFalse);
      expect(ScannedPage(png, reply('No_Characters', '', [])).isRead, isFalse);
      expect(ScannedPage(png, reply('Success', '', [50])).isRead, isFalse);
      expect(ScannedPage(png, {'error': 'x'}).isRead, isFalse);
    });

    test('a page with no detections has 0 confidence', () {
      expect(ScannedPage(png, null).confidence, 0);
    });
  });

  group('averageConfidence', () {
    test('skips non-numeric and non-finite values', () {
      expect(
        averageConfidence([
          {'confidence': 90},
          {'confidence': 'n/a'},
          {'confidence': double.nan},
          {},
          {'confidence': 70.0},
        ]),
        80,
      );
      expect(averageConfidence([]), 0);
    });
  });

  group('combined multi-page result', () {
    final pages = [
      ScannedPage(png, reply('Success', 'mahal', [100, 90])),
      ScannedPage(png, null), // failed page
      ScannedPage(png, reply('Low_Confidence', 'kita', [60])),
      ScannedPage(png, reply('Blurry_Image', '', [])),
    ];

    test('text joins only the pages that were read, one per line', () {
      expect(MultiPageResultScreen.combinedText(pages), 'mahal\nkita');
    });

    test('confidence averages every character of every page', () {
      expect(
        MultiPageResultScreen.combinedConfidence(pages),
        closeTo(83.33, 0.01),
      );
    });

    test('no readable pages -> empty text and 0 confidence', () {
      final none = [
        ScannedPage(png, null),
        ScannedPage(png, {'status': 'x'}),
      ];
      expect(MultiPageResultScreen.combinedText(none), '');
      expect(MultiPageResultScreen.combinedConfidence(none), 0);
    });
  });

  group('ResultExporter', () {
    tearDown(() => AppSettings.instance.language = 'en');

    test('TXT (English) contains the result, stats and breakdown', () {
      final text = ResultExporter.buildText(sampleExport());
      expect(text, contains('mahal kita'));
      expect(text, contains('Filter: HOG'));
      expect(text, contains('Words: 2'));
      expect(text, contains('Average confidence: 88%'));
      expect(text, contains('Line 1: ma ha'));
      expect(text, contains('ki'));
    });

    test('TXT follows the Filipino language setting', () {
      AppSettings.instance.language = 'fil';
      final text = ResultExporter.buildText(sampleExport());
      expect(text, contains('RESULTA (SA LATIN)'));
      expect(text, contains('Linya 1: ma ha'));
    });

    test('TXT handles an empty result and no characters', () {
      final empty = ResultExport(
        filteredImage: png,
        filter: 'Raw',
        imageWidth: 0,
        imageHeight: 0,
        boxes: const [],
        translatedText: '',
        averageConfidence: 0,
        characterCount: 0,
        lines: const [],
        createdAt: DateTime(2026),
      );
      final text = ResultExporter.buildText(empty);
      expect(text, contains('(no text)'));
      expect(text, contains('No individual characters detected.'));
      expect(text, isNot(contains('Average confidence')));
    });

    test('TXT export bytes are UTF-8', () async {
      final bytes = await ResultExporter.build(
        sampleExport(),
        ExportFormat.txt,
      );
      expect(utf8.decode(bytes), contains('mahal kita'));
    });

    test('PDF (A4, with bounding boxes) is a valid PDF', () async {
      final pdf = await ResultExporter.buildPdf(
        sampleExport(boxes: const [ExportBox(1, 1, 10, 10, 'ma', 95)]),
        singleImagePage: false,
      );
      expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    });

    test('single tall page (used for JPG/PNG) is a valid PDF', () async {
      final pdf = await ResultExporter.buildPdf(
        sampleExport(),
        singleImagePage: true,
      );
      expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    });

    test(
      'a broken image makes the export fail loudly (caught by the screen)',
      () async {
        final broken = sampleExport(image: Uint8List.fromList([1, 2, 3, 4]));
        await expectLater(
          ResultExporter.buildPdf(broken, singleImagePage: false),
          throwsA(anything),
        );
      },
    );

    test('PDF without characters or image size still builds', () async {
      final bare = ResultExport(
        filteredImage: png,
        filter: 'Raw',
        imageWidth: 0, // unknown size -> aspect ratio from the image itself
        imageHeight: 0,
        boxes: const [],
        translatedText: '',
        averageConfidence: 0,
        characterCount: 0,
        lines: const [],
        createdAt: DateTime(2026),
      );
      final pdf = await ResultExporter.buildPdf(bare, singleImagePage: false);
      expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
    });

    group('image formats and sharing (native parts replaced)', () {
      // 2x1 opaque RGBA pixels stand in for the rendered report.
      final fakeRaster = PdfRaster(
        2,
        1,
        Uint8List.fromList([255, 0, 0, 255, 0, 0, 255, 255]),
      );
      late Future<void> Function(ShareParams) realSharer;
      late Future<PdfRaster> Function(Uint8List) realRasterize;
      setUp(() {
        realSharer = ResultExporter.sharer;
        realRasterize = ResultExporter.rasterize;
        ResultExporter.rasterize = (pdf) async {
          expect(String.fromCharCodes(pdf.take(5)), '%PDF-');
          return fakeRaster;
        };
      });
      tearDown(() {
        ResultExporter.sharer = realSharer;
        ResultExporter.rasterize = realRasterize;
      });

      test('JPG is encoded from the rendered pixels', () async {
        final jpg = await ResultExporter.build(
          sampleExport(),
          ExportFormat.jpg,
        );
        expect(jpg.take(2), [0xFF, 0xD8]); // JPEG start-of-image marker
      });

      test('PNG comes from the rendered page', () async {
        final bytes = await ResultExporter.build(
          sampleExport(),
          ExportFormat.png,
        );
        expect(bytes.skip(1).take(3), 'PNG'.codeUnits);
      });

      test('rgbaToJpg keeps the image size', () {
        final decoded = img.decodeJpg(rgbaToJpg((2, 1, fakeRaster.pixels)))!;
        expect((decoded.width, decoded.height), (2, 1));
      });

      for (final format in ExportFormat.values) {
        test(
          'share hands a ${format.label} file with the right name and type',
          () async {
            ShareParams? shared;
            ResultExporter.sharer = (params) async => shared = params;
            await ResultExporter.share(sampleExport(), format);
            expect(shared!.fileNameOverrides, [
              'dayaw_20260929_140500.${format.extension}',
            ]);
            expect(shared!.files!.single.mimeType, format.mimeType);
          },
        );
      }

      test('a failing share sheet surfaces the error to the caller', () async {
        ResultExporter.sharer = (_) async => throw StateError('no share app');
        await expectLater(
          ResultExporter.share(sampleExport(), ExportFormat.txt),
          throwsStateError,
        );
      });
    });

    test('word count ignores extra spaces', () {
      final e = ResultExport(
        filteredImage: png,
        filter: 'HOG',
        imageWidth: 1,
        imageHeight: 1,
        boxes: const [],
        translatedText: '  mahal   kita \n bayan ',
        averageConfidence: 0,
        characterCount: 0,
        lines: const [],
        createdAt: DateTime(2026),
      );
      expect(e.wordCount, 3);
    });
  });
}
