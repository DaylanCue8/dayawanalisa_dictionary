import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:gal/gal.dart';
import 'package:image/image.dart' as img;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import 'app_language.dart';

/// Formats the Baybayin result screen can export to.
enum ExportFormat {
  jpg('JPG', 'jpg', 'image/jpeg'),
  png('PNG', 'png', 'image/png'),
  pdf('PDF', 'pdf', 'application/pdf'),
  txt('TXT', 'txt', 'text/plain');

  final String label;
  final String extension;
  final String mimeType;
  const ExportFormat(this.label, this.extension, this.mimeType);

  /// JPG/PNG go straight to the phone's Gallery; PDF/TXT use the share sheet.
  bool get savesToGallery => this == jpg || this == png;
}

/// One recognized character: its crop (as shown under the current
/// filter), the predicted Latin letter and the model's confidence (0-100).
class ExportCharacter {
  final Uint8List image;
  final String char;
  final double confidence;
  const ExportCharacter(this.image, this.char, this.confidence);
}

/// A detection's box in the source image's coordinate space.
class ExportBox {
  final double x0, y0, x1, y1;
  final String char;
  final double confidence;
  const ExportBox(
    this.x0,
    this.y0,
    this.x1,
    this.y1,
    this.char,
    this.confidence,
  );
}

/// Everything on the result screen at the moment Export is tapped.
class ResultExport {
  final Uint8List filteredImage;
  final String filter;
  final double imageWidth;
  final double imageHeight;

  /// Empty unless bounding boxes are switched on.
  final List<ExportBox> boxes;
  final String translatedText;
  final double averageConfidence;
  final int characterCount;
  final List<List<ExportCharacter>> lines;
  final DateTime createdAt;

  const ResultExport({
    required this.filteredImage,
    required this.filter,
    required this.imageWidth,
    required this.imageHeight,
    required this.boxes,
    required this.translatedText,
    required this.averageConfidence,
    required this.characterCount,
    required this.lines,
    required this.createdAt,
  });

  int get wordCount =>
      translatedText.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;
}

/// Builds the export file. JPG/PNG are saved directly to the phone's
/// Gallery (album [galleryAlbum]); PDF/TXT are handed to the system share
/// sheet, where they can be saved (Files, Drive) or sent.
class ResultExporter {
  ResultExporter._();

  /// Gallery album (Pictures/DAYAW) that JPG/PNG exports are saved into.
  static const String galleryAlbum = 'DAYAW';

  /// Opens the share sheet. Replaceable in tests (no native plugin there).
  @visibleForTesting
  static Future<void> Function(ShareParams params) sharer = (params) =>
      SharePlus.instance.share(params);

  /// Writes image bytes into the Gallery, asking for access first if
  /// needed. Replaceable in tests (no native plugin there).
  @visibleForTesting
  static Future<void> Function(Uint8List bytes, String name) gallerySaver =
      (bytes, name) async {
        if (!await Gal.hasAccess(toAlbum: true) &&
            !await Gal.requestAccess(toAlbum: true)) {
          throw StateError(
            tr(
              'permission to save to the Gallery was denied',
              'hindi pinayagang mag-save sa Gallery',
            ),
          );
        }
        await Gal.putImageBytes(bytes, album: galleryAlbum, name: name);
      };

  /// Turns a PDF into pixels (Android's PDF renderer, via printing).
  /// Replaceable in tests.
  ///
  /// The JPG/PNG report is ONE tall page whose height grows with the
  /// text, so a fixed 200 dpi could need a 1,200 x 11,000 px bitmap
  /// (13+ million pixels, ~50 MB, several copies) - enough to make
  /// Android kill the app. So the page is measured first with a tiny,
  /// cheap render, and the real render uses the highest dpi (up to 200)
  /// that stays under [maxRasterPixels].
  @visibleForTesting
  static Future<PdfRaster> Function(Uint8List pdf) rasterize = (pdf) async {
    const probeDpi = 18.0;
    final probe = await Printing.raster(pdf, dpi: probeDpi).first;
    final widthPt = probe.width * 72 / probeDpi;
    final heightPt = probe.height * 72 / probeDpi;
    return Printing.raster(pdf, dpi: safeRasterDpi(widthPt, heightPt)).first;
  };

  /// Largest picture (in pixels) the JPG/PNG export may create. 6 million
  /// pixels is ~24 MB per copy - safe on low-memory phones.
  static const int maxRasterPixels = 6000000;

  /// Highest dpi (60-200) whose rendered page stays under
  /// [maxRasterPixels]. [widthPt]/[heightPt] are the page size in points.
  @visibleForTesting
  static double safeRasterDpi(double widthPt, double heightPt) {
    if (widthPt <= 0 || heightPt <= 0) return 100;
    final dpi = 72 * math.sqrt(maxRasterPixels / (widthPt * heightPt));
    return dpi.clamp(60.0, 200.0).toDouble();
  }

  /// Saves JPG/PNG to the Gallery, or opens the share sheet for PDF/TXT.
  static Future<void> export(ResultExport data, ExportFormat format) =>
      format.savesToGallery
          ? saveToGallery(data, format)
          : share(data, format);

  static Future<void> saveToGallery(
    ResultExport data,
    ExportFormat format,
  ) async {
    final bytes = await build(data, format);
    await gallerySaver(bytes, 'dayaw_${_stamp(data.createdAt)}');
  }

  static Future<void> share(ResultExport data, ExportFormat format) async {
    final bytes = await build(data, format);
    await sharer(
      ShareParams(
        files: [XFile.fromData(bytes, mimeType: format.mimeType)],
        fileNameOverrides: [fileName(data, format)],
        subject: 'DAYAW Baybayin result',
      ),
    );
  }

  /// e.g. dayaw_20260929_140500.pdf
  static String fileName(ResultExport data, ExportFormat format) =>
      'dayaw_${_stamp(data.createdAt)}.${format.extension}';

  static Future<Uint8List> build(ResultExport data, ExportFormat format) async {
    switch (format) {
      case ExportFormat.txt:
        return Uint8List.fromList(utf8.encode(buildText(data)));
      case ExportFormat.pdf:
        return buildPdf(data, singleImagePage: false);
      case ExportFormat.png:
      case ExportFormat.jpg:
        // The same report, laid out as one tall page and rasterized.
        final pdf = await buildPdf(data, singleImagePage: true);
        final raster = await rasterize(pdf);
        if (format == ExportFormat.png) return raster.toPng();
        return compute(rgbaToJpg, (raster.width, raster.height, raster.pixels));
    }
  }

  // -------------------------------------------------------------------
  // TXT
  // -------------------------------------------------------------------

  static String buildText(ResultExport data) {
    final b = StringBuffer()
      ..writeln(
        tr(
          'DAYAW - Baybayin to Latin result',
          'DAYAW - Resulta ng Baybayin sa Latin',
        ),
      )
      ..writeln(
        '${tr('Exported', 'Na-export')}: ${_readableDate(data.createdAt)}',
      )
      ..writeln()
      ..writeln(tr('RESULT (IN LATIN)', 'RESULTA (SA LATIN)'))
      ..writeln(
        data.translatedText.isEmpty
            ? tr('(no text)', '(walang teksto)')
            : data.translatedText,
      )
      ..writeln()
      ..writeln('Filter: ${data.filter}')
      ..writeln('${tr('Characters', 'Karakter')}: ${data.characterCount}')
      ..writeln('${tr('Words', 'Salita')}: ${data.wordCount}')
      ..writeln('${tr('Lines', 'Linya')}: ${data.lines.length}');
    if (data.averageConfidence > 0) {
      b.writeln(
        '${tr('Average confidence', 'Karaniwang kumpiyansa')}: '
        '${data.averageConfidence.round()}%',
      );
    }
    b
      ..writeln()
      ..writeln(tr('CHARACTER BREAKDOWN', 'BAWAT KARAKTER'));
    if (data.lines.isEmpty) {
      b.writeln(
        tr('No individual characters detected.', 'Walang nakitang karakter.'),
      );
    }
    for (var i = 0; i < data.lines.length; i++) {
      final line = data.lines[i];
      b
        ..writeln()
        ..writeln(
          '${tr('Line', 'Linya')} ${i + 1}: ${line.map((c) => c.char).join(' ')}',
        );
      for (var j = 0; j < line.length; j++) {
        b.writeln(
          '  ${j + 1}. ${line[j].char.padRight(4)} '
          '${line[j].confidence.toStringAsFixed(1)}%',
        );
      }
    }
    b
      ..writeln()
      ..writeln(
        tr(
          '(c) 2026 DAYAW. All rights reserved.',
          '(c) 2026 DAYAW. Nakalaan ang lahat ng karapatan.',
        ),
      );
    return b.toString();
  }

  // -------------------------------------------------------------------
  // PDF (also the source for PNG / JPG)
  // -------------------------------------------------------------------

  // Same muted-honey palette as the app (see DayawColors).
  static const _deepBrown = PdfColor.fromInt(0xFF1E1C19);
  static const _softBrown = PdfColor.fromInt(0xFF3A3733);

  /// The report follows the app's theme at the moment of export.
  static bool get _gradientTheme => false;
  static const _amber = PdfColor.fromInt(0xFFC99A0E);
  static const _yellow = PdfColor.fromInt(0xFFF2C230);
  static const _gold = PdfColor.fromInt(0xFFF7DE8A);
  static const _cream = PdfColor.fromInt(0xFFF4F0E8);
  static const _card = PdfColor.fromInt(0xFFF0EBE3);
  static const _muted = PdfColor.fromInt(0xFF6E685E);

  static PdfColor _confidenceColor(double c) {
    if (c >= 90) return const PdfColor.fromInt(0xFF3E7D3A);
    if (c >= 75) return const PdfColor.fromInt(0xFFC99A0E);
    return const PdfColor.fromInt(0xFFB3473C);
  }

  static Future<Uint8List> buildPdf(
    ResultExport data, {
    required bool singleImagePage,
  }) async {
    final doc = pw.Document(
      title: 'DAYAW Baybayin result',
      author: 'DAYAW',
      creator: 'DAYAW',
    );
    final theme = pw.ThemeData.withFont(
      base: pw.Font.helvetica(),
      bold: pw.Font.helveticaBold(),
    );
    final background = pw.PageTheme(
      theme: theme,
      pageFormat: singleImagePage
          ? const PdfPageFormat(420, double.infinity, marginAll: 24)
          : PdfPageFormat.a4.copyWith(
              marginLeft: 36,
              marginRight: 36,
              marginTop: 32,
              marginBottom: 32,
            ),
      buildBackground: (context) =>
          pw.FullPage(ignoreMargins: true, child: pw.Container(color: _cream)),
    );

    final sections = <pw.Widget>[
      _header(data),
      pw.SizedBox(height: 16),
      _sectionTitle(tr('Scanned image', 'Na-scan na larawan')),
      pw.SizedBox(height: 8),
      _imageSection(data, maxHeight: singleImagePage ? 420 : 300),
      pw.SizedBox(height: 18),
      _sectionTitle(tr('Results', 'Mga Resulta')),
      pw.SizedBox(height: 8),
      _resultCard(data),
      pw.SizedBox(height: 18),
      _sectionTitle(tr('Character breakdown', 'Bawat karakter')),
      pw.SizedBox(height: 8),
      if (data.lines.isEmpty)
        pw.Text(
          tr('No individual characters detected.', 'Walang nakitang karakter.'),
          style: const pw.TextStyle(color: _muted),
        ),
      for (var i = 0; i < data.lines.length; i++)
        _lineSection(i + 1, data.lines[i]),
      pw.SizedBox(height: 12),
      pw.Center(
        child: pw.Text(
          tr(
            '© 2026 DAYAW. All rights reserved.',
            '© 2026 DAYAW. Nakalaan ang lahat ng karapatan.',
          ),
          style: const pw.TextStyle(fontSize: 8, color: _muted),
        ),
      ),
    ];

    if (singleImagePage) {
      doc.addPage(
        pw.Page(
          pageTheme: background,
          build: (context) => pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.stretch,
            children: sections,
          ),
        ),
      );
    } else {
      doc.addPage(
        pw.MultiPage(
          pageTheme: background,
          footer: (context) => pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(
              tr(
                'Page ${context.pageNumber} of ${context.pagesCount}',
                'Pahina ${context.pageNumber} ng ${context.pagesCount}',
              ),
              style: const pw.TextStyle(fontSize: 8, color: _muted),
            ),
          ),
          build: (context) => sections,
        ),
      );
    }
    return doc.save();
  }

  static pw.Widget _header(ResultExport data) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: pw.BoxDecoration(
        borderRadius: pw.BorderRadius.circular(14),
        color: _gradientTheme ? null : _deepBrown,
        gradient: _gradientTheme
            ? const pw.LinearGradient(colors: [_deepBrown, _softBrown])
            : null,
      ),
      child: pw.Row(
        children: [
          pw.Expanded(
            child: pw.Column(
              crossAxisAlignment: pw.CrossAxisAlignment.start,
              children: [
                pw.Text(
                  'DAYAW',
                  style: pw.TextStyle(
                    fontSize: 20,
                    fontWeight: pw.FontWeight.bold,
                    color: _gold,
                    letterSpacing: 2,
                  ),
                ),
                pw.SizedBox(height: 2),
                pw.Text(
                  tr(
                    'Baybayin to Latin result',
                    'Resulta ng Baybayin sa Latin',
                  ),
                  style: const pw.TextStyle(
                    fontSize: 10,
                    color: PdfColors.white,
                  ),
                ),
              ],
            ),
          ),
          pw.Text(
            _readableDate(data.createdAt),
            style: const pw.TextStyle(fontSize: 9, color: _gold),
          ),
        ],
      ),
    );
  }

  static pw.Widget _sectionTitle(String text) {
    return pw.Row(
      children: [
        pw.Container(
          width: 4,
          height: 14,
          decoration: pw.BoxDecoration(
            color: _amber,
            borderRadius: pw.BorderRadius.circular(2),
          ),
        ),
        pw.SizedBox(width: 6),
        pw.Text(
          text,
          style: pw.TextStyle(
            fontSize: 13,
            fontWeight: pw.FontWeight.bold,
            color: _deepBrown,
          ),
        ),
      ],
    );
  }

  /// The image under the selected filter, boxes drawn on top when they
  /// were switched on - the same view as on screen.
  static pw.Widget _imageSection(
    ResultExport data, {
    required double maxHeight,
  }) {
    final image = pw.MemoryImage(data.filteredImage);
    final hasSize = data.imageWidth > 0 && data.imageHeight > 0;
    final aspect = hasSize
        ? data.imageWidth / data.imageHeight
        : image.width! / image.height!;

    return pw.Container(
      padding: const pw.EdgeInsets.all(6),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        borderRadius: pw.BorderRadius.circular(12),
        border: pw.Border.all(color: _yellow),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.stretch,
        children: [
          pw.Center(
            child: pw.ConstrainedBox(
              constraints: pw.BoxConstraints(maxHeight: maxHeight),
              child: pw.AspectRatio(
                aspectRatio: aspect,
                child: pw.LayoutBuilder(
                  builder: (context, constraints) {
                    final w = constraints!.maxWidth;
                    final h = constraints.maxHeight;
                    return pw.Stack(
                      children: [
                        pw.Image(
                          image,
                          fit: pw.BoxFit.fill,
                          width: w,
                          height: h,
                        ),
                        if (hasSize)
                          for (final box in data.boxes)
                            ..._box(
                              box,
                              w / data.imageWidth,
                              h / data.imageHeight,
                            ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
          pw.SizedBox(height: 6),
          pw.Row(
            children: [
              _pill('Filter: ${data.filter}'),
              if (data.boxes.isNotEmpty) ...[
                pw.SizedBox(width: 6),
                _pill(tr('Bounding boxes shown', 'May bounding box')),
              ],
            ],
          ),
        ],
      ),
    );
  }

  static List<pw.Widget> _box(ExportBox box, double sx, double sy) {
    final color = _confidenceColor(box.confidence);
    final left = box.x0 * sx;
    final top = box.y0 * sy;
    return [
      pw.Positioned(
        left: left,
        top: top,
        child: pw.Container(
          width: (box.x1 - box.x0) * sx,
          height: (box.y1 - box.y0) * sy,
          decoration: pw.BoxDecoration(
            border: pw.Border.all(color: color, width: 1.2),
          ),
        ),
      ),
      pw.Positioned(
        left: left,
        top: top > 11 ? top - 11 : top,
        child: pw.Container(
          color: color,
          padding: const pw.EdgeInsets.symmetric(horizontal: 2, vertical: 1),
          child: pw.Text(
            box.char,
            style: pw.TextStyle(
              fontSize: 7,
              color: PdfColors.white,
              fontWeight: pw.FontWeight.bold,
            ),
          ),
        ),
      ),
    ];
  }

  static pw.Widget _resultCard(ResultExport data) {
    final conf = data.averageConfidence;
    return pw.Container(
      padding: const pw.EdgeInsets.all(14),
      decoration: pw.BoxDecoration(
        color: _card,
        borderRadius: pw.BorderRadius.circular(14),
        border: pw.Border.all(color: _yellow),
      ),
      child: pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            children: [
              pw.Container(
                padding: const pw.EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 3,
                ),
                decoration: pw.BoxDecoration(
                  color: _gradientTheme ? null : _yellow,
                  gradient: _gradientTheme
                      ? const pw.LinearGradient(
                          colors: [_gold, _yellow, _amber],
                        )
                      : null,
                  borderRadius: pw.BorderRadius.circular(10),
                ),
                child: pw.Text(
                  tr('IN LATIN', 'SA LATIN'),
                  style: pw.TextStyle(
                    fontSize: 8,
                    fontWeight: pw.FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ),
              pw.Spacer(),
              if (conf > 0)
                pw.Text(
                  '${conf.round()}% ${tr('confidence', 'kumpiyansa')}',
                  style: pw.TextStyle(
                    fontSize: 10,
                    fontWeight: pw.FontWeight.bold,
                    color: _confidenceColor(conf),
                  ),
                ),
            ],
          ),
          pw.SizedBox(height: 10),
          pw.Text(
            data.translatedText.isEmpty ? '-' : data.translatedText,
            style: pw.TextStyle(
              fontSize: 22,
              fontWeight: pw.FontWeight.bold,
              color: _deepBrown,
            ),
          ),
          pw.SizedBox(height: 10),
          pw.Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              _pill('${data.characterCount} ${tr('characters', 'karakter')}'),
              _pill(
                tr(
                  '${data.wordCount} ${data.wordCount == 1 ? 'word' : 'words'}',
                  '${data.wordCount} salita',
                ),
              ),
              _pill(
                tr(
                  '${data.lines.length} ${data.lines.length == 1 ? 'line' : 'lines'}',
                  '${data.lines.length} linya',
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static pw.Widget _lineSection(int number, List<ExportCharacter> line) {
    return pw.Container(
      margin: const pw.EdgeInsets.only(bottom: 10),
      padding: const pw.EdgeInsets.all(10),
      decoration: pw.BoxDecoration(
        color: PdfColors.white,
        borderRadius: pw.BorderRadius.circular(12),
        border: pw.Border.all(color: _gold),
      ),
      child: pw.Row(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Container(
            width: 34,
            padding: const pw.EdgeInsets.symmetric(vertical: 6),
            decoration: pw.BoxDecoration(
              borderRadius: pw.BorderRadius.circular(8),
              color: _gradientTheme ? null : _deepBrown,
              gradient: _gradientTheme
                  ? const pw.LinearGradient(colors: [_deepBrown, _softBrown])
                  : null,
            ),
            child: pw.Column(
              children: [
                pw.Text(
                  '$number',
                  style: pw.TextStyle(
                    fontSize: 16,
                    fontWeight: pw.FontWeight.bold,
                    color: _gold,
                  ),
                ),
                pw.Text(
                  tr('LINE', 'LINYA'),
                  style: const pw.TextStyle(
                    fontSize: 6,
                    color: PdfColors.white,
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(width: 10),
          pw.Expanded(
            child: pw.Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final c in line) _characterCard(c)],
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _characterCard(ExportCharacter c) {
    return pw.Container(
      width: 54,
      padding: const pw.EdgeInsets.all(4),
      decoration: pw.BoxDecoration(
        color: _cream,
        borderRadius: pw.BorderRadius.circular(8),
        border: pw.Border.all(color: _yellow, width: 0.8),
      ),
      child: pw.Column(
        children: [
          pw.Container(
            width: 44,
            height: 44,
            color: PdfColors.black,
            child: pw.Image(pw.MemoryImage(c.image), fit: pw.BoxFit.contain),
          ),
          pw.SizedBox(height: 3),
          pw.Text(
            c.char,
            style: pw.TextStyle(
              fontSize: 11,
              fontWeight: pw.FontWeight.bold,
              color: _deepBrown,
            ),
          ),
          pw.Text(
            '${c.confidence.round()}%',
            style: pw.TextStyle(
              fontSize: 7,
              color: _confidenceColor(c.confidence),
            ),
          ),
        ],
      ),
    );
  }

  static pw.Widget _pill(String text) {
    return pw.Container(
      padding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: pw.BoxDecoration(
        color: _gold,
        borderRadius: pw.BorderRadius.circular(10),
        border: pw.Border.all(color: _amber, width: 0.6),
      ),
      child: pw.Text(
        text,
        style: const pw.TextStyle(fontSize: 8, color: _deepBrown),
      ),
    );
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _stamp(DateTime t) =>
      '${t.year}${_two(t.month)}${_two(t.day)}_'
      '${_two(t.hour)}${_two(t.minute)}${_two(t.second)}';

  static String _readableDate(DateTime t) =>
      '${t.year}-${_two(t.month)}-${_two(t.day)} ${_two(t.hour)}:${_two(t.minute)}';
}

/// RGBA pixels -> JPG. The report paints its own opaque cream background,
/// so dropping alpha is safe. Top-level so it can run via compute.
@visibleForTesting
Uint8List rgbaToJpg((int, int, Uint8List) raster) {
  final (width, height, pixels) = raster;
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: pixels.buffer,
    numChannels: 4,
  );
  return Uint8List.fromList(img.encodeJpg(image, quality: 92));
}