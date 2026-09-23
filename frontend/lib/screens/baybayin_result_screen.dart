import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

/// Full-screen results view for the Baybayin-to-Latin flow, reached after
/// a successful translate call. Shows the predicted output, a copy
/// button, and a side-by-side table of each captured character crop
/// against its predicted Latin equivalent.
class BaybayinResultScreen extends StatefulWidget {
  final Uint8List sourceImage;
  final String translatedText;
  final List<Map<String, dynamic>> detections;

  // The backend's reported dimensions for the image it computed bbox
  // coordinates against. These are NOT guaranteed to equal
  // img.decodeImage(sourceImage)'s own width/height - e.g. the pen
  // pipeline's enhance_image_quality step can upscale the image
  // in-memory before computing bboxes, so the backend's stated
  // dimensions can be larger than sourceImage's native decoded size.
  // Without scaling by the ratio between these two, bbox coordinates
  // land on the wrong sub-region when cropped locally (this was the
  // bug: crops showing only part of a letter, e.g. half of "ba").
  final double imageWidth;
  final double imageHeight;

  const BaybayinResultScreen({
    super.key,
    required this.sourceImage,
    required this.translatedText,
    required this.detections,
    required this.imageWidth,
    required this.imageHeight,
  });

  @override
  State<BaybayinResultScreen> createState() => _BaybayinResultScreenState();
}

class _BaybayinResultScreenState extends State<BaybayinResultScreen> {
  late final List<_CharacterResult> _characterResults;

  @override
  void initState() {
    super.initState();
    _characterResults = _buildCharacterResults();
  }

  /// Crops each detected glyph out of the same image that was sent to the
  /// backend. bbox coordinates are pixel coordinates relative to the
  /// backend's reported (imageWidth, imageHeight) - NOT necessarily the
  /// same as sourceImage's own decoded dimensions (see the field docs
  /// above), so a scale factor is computed and applied before cropping.
  /// Mirrors the >=23% confidence floor used elsewhere in the app so
  /// stray low-confidence noise doesn't clutter the breakdown.
  List<_CharacterResult> _buildCharacterResults() {
    final decoded = img.decodeImage(widget.sourceImage);
    final results = <_CharacterResult>[];
    if (decoded == null) return results;

    // Scale factor between the backend's coordinate space (what bbox
    // values are expressed in) and this locally-decoded image's actual
    // pixel dimensions. When they already match (the common case for
    // marker input, which never resizes), these are both 1.0 and every
    // crop behaves exactly as before.
    final double scaleX = widget.imageWidth > 0
        ? decoded.width / widget.imageWidth
        : 1.0;
    final double scaleY = widget.imageHeight > 0
        ? decoded.height / widget.imageHeight
        : 1.0;

    for (final d in widget.detections) {
      final conf = (d['confidence'] as num?)?.toDouble() ?? 0.0;
      if (conf < 23.0) continue;
      final bbox = d['bbox'] as Map<String, dynamic>?;
      if (bbox == null) continue;

      final rawX0 = (bbox['x0'] as num).toDouble();
      final rawY0 = (bbox['y0'] as num).toDouble();
      final rawX1 = (bbox['x1'] as num).toDouble();
      final rawY1 = (bbox['y1'] as num).toDouble();

      final x0 = (rawX0 * scaleX).round().clamp(0, decoded.width - 1);
      final y0 = (rawY0 * scaleY).round().clamp(0, decoded.height - 1);
      final x1 = (rawX1 * scaleX).round().clamp(x0 + 1, decoded.width);
      final y1 = (rawY1 * scaleY).round().clamp(y0 + 1, decoded.height);

      final crop = img.copyCrop(
        decoded,
        x: x0,
        y: y0,
        width: x1 - x0,
        height: y1 - y0,
      );

      results.add(_CharacterResult(
        image: Uint8List.fromList(img.encodePng(crop)),
        char: d['char']?.toString() ?? '?',
        confidence: conf,
      ));
    }
    return results;
  }

  Color _confidenceColor(double conf) {
    if (conf >= 90.0) return Colors.green;
    if (conf >= 80.0) return Colors.amber[800]!;
    if (conf >= 70.0) return Colors.red;
    return Colors.grey;
  }

  void _copyResult() {
    Clipboard.setData(ClipboardData(text: widget.translatedText));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Copied to clipboard'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text('Translation Result'),
        backgroundColor: Colors.white,
        foregroundColor: Colors.brown,
        elevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildOriginalImageCard(),
              const SizedBox(height: 24),
              _buildPredictedOutputCard(),
              const SizedBox(height: 24),
              const Text(
                'Character Breakdown',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
              ),
              const SizedBox(height: 12),
              _buildCharacterTable(),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildOriginalImageCard() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F5),
          border: Border.all(color: Colors.brown.withOpacity(0.2)),
        ),
        constraints: const BoxConstraints(maxHeight: 320),
        child: Image.memory(widget.sourceImage, fit: BoxFit.contain),
      ),
    );
  }

  Widget _buildPredictedOutputCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.brown.withOpacity(0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.brown.withOpacity(0.2)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              widget.translatedText.isEmpty ? '—' : widget.translatedText,
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.bold,
                color: Colors.brown,
              ),
            ),
          ),
          IconButton(
            onPressed: _copyResult,
            icon: const Icon(Icons.copy, color: Colors.brown),
            tooltip: 'Copy result',
          ),
        ],
      ),
    );
  }

  Widget _buildCharacterTable() {
    if (_characterResults.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            'No individual characters detected.',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return Table(
      border: TableBorder.all(
        color: Colors.brown.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      columnWidths: const {
        0: FlexColumnWidth(1),
        1: FlexColumnWidth(1),
      },
      children: [
        TableRow(
          decoration: BoxDecoration(color: Colors.brown.withOpacity(0.08)),
          children: const [
            Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: Text('Captured Character', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(vertical: 10),
              child: Center(
                child: Text('Predicted Character', style: TextStyle(fontWeight: FontWeight.bold)),
              ),
            ),
          ],
        ),
        for (final result in _characterResults)
          TableRow(
            children: [
              Padding(
                padding: const EdgeInsets.all(10),
                child: Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(result.image, height: 56, width: 56, fit: BoxFit.contain),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        result.char,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                          color: _confidenceColor(result.confidence),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${result.confidence.toStringAsFixed(0)}%',
                        style: TextStyle(fontSize: 12, color: _confidenceColor(result.confidence)),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _CharacterResult {
  final Uint8List image;
  final String char;
  final double confidence;

  _CharacterResult({required this.image, required this.char, required this.confidence});
}