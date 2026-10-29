// The image/PDF export must draw Baybayin (not empty boxes) and the JPG
// must keep the report's colors.
import 'dart:typed_data';

import 'package:dayaw/services/result_exporter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart' show TtfParser;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('the bundled Baybayin font covers the Baybayin letters', () async {
    final data = await rootBundle.load('assets/fonts/baybayin_custom.ttf');
    final glyphs = TtfParser(data).charToGlyphIndexMap;
    // ba, ka, a, kudlit i, kudlit u, virama
    for (final rune in [0x170A, 0x1703, 0x1700, 0x1712, 0x1713, 0x1714]) {
      expect(
        glyphs.containsKey(rune),
        isTrue,
        reason: 'U+${rune.toRadixString(16)}',
      );
    }
  });

  test('a report with Baybayin text still builds', () async {
    final pdf = await ResultExporter.buildPdf(
      ResultExport(
        filteredImage: img.encodePng(img.Image(width: 1, height: 1)),
        filter: 'Raw',
        imageWidth: 0,
        imageHeight: 0,
        boxes: const [],
        translatedText: 'ᜊᜑᜌ᜔\nRead as: bahay',
        averageConfidence: 90,
        characterCount: 4,
        lines: const [],
        createdAt: DateTime(2026, 10, 29),
      ),
      singleImagePage: true,
    );
    expect(pdf, isNotEmpty);
  });

  test('JPG keeps colors, even where pixels are not fully opaque', () {
    // One opaque sunflower-yellow pixel, one half-transparent black one.
    final pixels = Uint8List.fromList([
      0xF2, 0xC2, 0x30, 0xFF, //
      0x00, 0x00, 0x00, 0x80,
    ]);
    final jpg = img.decodeJpg(rgbaToJpg((2, 1, pixels)))!;
    final yellow = jpg.getPixel(0, 0);
    expect((yellow.r - 0xF2).abs(), lessThan(14));
    expect((yellow.g - 0xC2).abs(), lessThan(14));
    expect((yellow.b - 0x30).abs(), lessThan(24));
    // Laid on the report's cream, not on white.
    final blended = jpg.getPixel(1, 0);
    expect(blended.r, lessThan(0xC0));
  });
}
