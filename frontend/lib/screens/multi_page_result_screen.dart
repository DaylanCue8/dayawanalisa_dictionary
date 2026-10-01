import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_language.dart';
import '../services/app_settings.dart';
import '../services/recognition_outcome.dart';
import '../widgets/dayaw_style.dart';
import '../widgets/glass.dart';
import 'baybayin_result_screen.dart';

/// One photographed page and what the recognizer made of it. [data] is
/// the recognizer's response (same map as a single scan), or null when
/// that page couldn't be read.
class ScannedPage {
  final Uint8List image;
  final Map<String, dynamic>? data;
  const ScannedPage(this.image, this.data);

  String get text => data?['translated_text']?.toString() ?? '';

  List<Map<String, dynamic>> get detections => scannedDetections(data);

  RecognitionOutcome get outcome => RecognitionOutcome.of(data);

  /// True when this page produced text to show.
  bool get isRead => outcome.hasText && text.isNotEmpty;

  /// Average confidence (0-100) over this page's characters.
  double get confidence => averageConfidence(detections);
}

/// Mean of the numeric 'confidence' values in [detections] (0 if none).
/// Non-numeric or missing values are skipped rather than crashing.
double averageConfidence(Iterable<Map<String, dynamic>> detections) {
  final values = [
    for (final d in detections)
      if (d['confidence'] is num && (d['confidence'] as num).isFinite)
        (d['confidence'] as num).toDouble(),
  ];
  if (values.isEmpty) return 0;
  return values.reduce((a, b) => a + b) / values.length;
}

/// Results of a multi-page scan: every page's text combined (with Copy
/// all), then one card per page. Tapping a page opens the regular
/// single-page result screen for it - filters, breakdown and export.
class MultiPageResultScreen extends StatelessWidget {
  final List<ScannedPage> pages;

  const MultiPageResultScreen({super.key, required this.pages});

  /// Pages that were read, joined one per line - also what the scan tab
  /// shows as the result.
  static String combinedText(List<ScannedPage> pages) =>
      pages.where((p) => p.isRead).map((p) => p.text).join('\n');

  /// Average over every character of every page (not an average of page
  /// averages, so a page with more letters counts for more).
  static double combinedConfidence(List<ScannedPage> pages) =>
      averageConfidence([for (final p in pages) ...p.detections]);

  static Color _confidenceColor(double c) {
    if (c >= 90) return const Color(0xFF5E8B5A);
    if (c >= 75) return const Color(0xFFC2873F);
    return DayawColors.brick;
  }

  void _copyAll(BuildContext context) {
    Clipboard.setData(ClipboardData(text: combinedText(pages)));
    if (AppSettings.instance.hapticsEnabled) HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Copied all pages', 'Nakopya ang lahat ng pahina')),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _openPage(BuildContext context, ScannedPage page) {
    if (!page.isRead) return;
    if (AppSettings.instance.hapticsEnabled) HapticFeedback.selectionClick();
    final data = page.data!;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BaybayinResultScreen(
          sourceImage: page.image,
          translatedText: page.text,
          detections: page.detections,
          imageWidth: readNumber(data, 'image_width'),
          imageHeight: readNumber(data, 'image_height'),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(
          context.tr('${pages.length} pages', '${pages.length} pahina'),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: Colors.brown,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: const GlassBar(child: SizedBox.expand()),
      ),
      body: GlassBackground(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            20,
            topInset + 16,
            20,
            20 + MediaQuery.paddingOf(context).bottom,
          ),
          children: [
            DayawSectionTitle(
              context.tr('Results', 'Mga Resulta'),
              Icons.translate,
            ),
            const SizedBox(height: 12),
            _buildCombinedCard(context),
            const SizedBox(height: 28),
            DayawSectionTitle(
              context.tr('Pages', 'Mga Pahina'),
              Icons.auto_stories_outlined,
            ),
            const SizedBox(height: 4),
            Text(
              context.tr(
                'Tap a page for its filters, character breakdown and export.',
                'I-tap ang pahina para sa filter, bawat karakter at pag-export.',
              ),
              style: const TextStyle(fontSize: 12.5, color: Colors.black54),
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < pages.length; i++)
              _buildPageCard(context, i + 1, pages[i]),
            const SizedBox(height: 8),
            Text(
              context.tr(
                '© 2026 DAYAW. All rights reserved.',
                '© 2026 DAYAW. Nakalaan ang lahat ng karapatan.',
              ),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCombinedCard(BuildContext context) {
    final text = combinedText(pages);
    final confidence = combinedConfidence(pages);
    final read = pages.where((p) => p.isRead).length;
    final characters = pages.fold<int>(0, (n, p) => n + p.detections.length);
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

    return GlassContainer(
      padding: const EdgeInsets.all(18),
      tint: const Color(0xA6FFF4B8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _pill(context.tr('IN LATIN', 'SA LATIN')),
              const Spacer(),
              if (confidence > 0) _confidenceRing(confidence),
            ],
          ),
          const SizedBox(height: 12),
          SelectableText(
            text.isEmpty ? '—' : text,
            style: const TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w900,
              color: DayawColors.deepBrown,
              height: 1.3,
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _statChip(
                Icons.auto_stories_outlined,
                read == pages.length
                    ? context.tr(
                        '${pages.length} pages',
                        '${pages.length} pahina',
                      )
                    : context.tr(
                        '$read of ${pages.length} pages read',
                        '$read sa ${pages.length} pahina ang nabasa',
                      ),
              ),
              _statChip(
                Icons.text_fields,
                context.tr('$characters characters', '$characters karakter'),
              ),
              _statChip(
                Icons.short_text,
                context.tr(
                  '$words ${words == 1 ? 'word' : 'words'}',
                  '$words salita',
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: text.isEmpty ? null : () => _copyAll(context),
              style: FilledButton.styleFrom(
                backgroundColor: DayawColors.deepBrown,
                foregroundColor: DayawColors.yellow,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              icon: const Icon(Icons.copy_rounded, size: 18),
              label: Text(
                context.tr('Copy all pages', 'Kopyahin ang lahat ng pahina'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPageCard(BuildContext context, int number, ScannedPage page) {
    final read = page.isRead;
    return GestureDetector(
      onTap: () => _openPage(context, page),
      child: GlassContainer(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(10),
        borderRadius: const BorderRadius.all(Radius.circular(18)),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(
                page.image,
                width: 64,
                height: 84,
                fit: BoxFit.cover,
                cacheWidth: 200,
                gaplessPlayback: true,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    context.tr('PAGE $number', 'PAHINA $number'),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                      color: DayawColors.softBrown,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    read
                        ? (page.text.isEmpty ? '—' : page.text)
                        : context.tr(
                            'No Baybayin letters found on this page.',
                            'Walang nakitang titik ng Baybayin sa pahinang ito.',
                          ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: read ? 17 : 13,
                      fontWeight: read ? FontWeight.w800 : FontWeight.w500,
                      color: read ? DayawColors.deepBrown : DayawColors.brick,
                    ),
                  ),
                  if (read) ...[
                    const SizedBox(height: 6),
                    Text(
                      context.tr(
                        '${page.detections.length} characters'
                            '${page.confidence > 0 ? ' · ${page.confidence.round()}% confidence' : ''}',
                        '${page.detections.length} karakter'
                            '${page.confidence > 0 ? ' · ${page.confidence.round()}% kumpiyansa' : ''}',
                      ),
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: _confidenceColor(page.confidence),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (read)
              Icon(
                Icons.chevron_right,
                color: DayawColors.deepBrown.withValues(alpha: 0.4),
              ),
          ],
        ),
      ),
    );
  }

  Widget _pill(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: DayawColors.yellow,
        gradient: themedGradient(
          const LinearGradient(
            colors: [DayawColors.gold, DayawColors.yellow, DayawColors.amber],
          ),
        ),
        borderRadius: BorderRadius.circular(20),
        boxShadow: const [BoxShadow(color: Color(0x33D9A441), blurRadius: 8)],
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w900,
          letterSpacing: 1,
          color: Colors.black87,
        ),
      ),
    );
  }

  Widget _confidenceRing(double confidence) {
    final color = _confidenceColor(confidence);
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: confidence / 100),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => SizedBox(
        width: 54,
        height: 54,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.expand(
              child: CircularProgressIndicator(
                value: value,
                strokeWidth: 5,
                strokeCap: StrokeCap.round,
                color: color,
                backgroundColor: color.withValues(alpha: 0.15),
              ),
            ),
            Text(
              '${(value * 100).round()}%',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: DayawColors.yellow.withValues(alpha: 0.45),
        gradient: themedGradient(
          LinearGradient(
            colors: [
              DayawColors.yellow.withValues(alpha: 0.55),
              DayawColors.gold.withValues(alpha: 0.35),
            ],
          ),
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: DayawColors.amber.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.brown),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: DayawColors.deepBrown,
            ),
          ),
        ],
      ),
    );
  }
}
