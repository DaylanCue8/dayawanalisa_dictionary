import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show applyBoxFit, FittedSizes;
import 'package:flutter/services.dart';
import '../services/app_language.dart';
import '../services/app_settings.dart';
import '../services/offline_recognizer.dart';
import '../services/recognition_outcome.dart';
import '../widgets/image_cropper_widget.dart';
import '../screens/camera_capture_screen.dart';
import '../screens/latin_result_screen.dart';
import '../widgets/dayaw_style.dart';
import '../widgets/embroidery.dart';
import '../widgets/glass.dart';

/// Handles the "Latin to Baybayin" mode: take a photo of HANDWRITTEN Latin
/// (printed letters), crop it, read every letter on the phone with the
/// Latin SVM, and show the Baybayin.
///
/// Replaces the old typed "Filipino to Baybayin" mode. The class keeps its
/// old name (TagalogToBaybayinView) so the tab that opens it does not have
/// to change - only the label on the tab should now say "Latin → Baybayin".
///
/// Same look as the Baybayin to Latin tab: shimmering hero header, a
/// glowing scanner card with word boxes, a pop-in result card with a
/// confidence ring, writing tips and rotating Baybayin facts. The
/// syllable and letter breakdowns are on LatinResultScreen, which opens
/// after a scan (like BaybayinResultScreen on the other tab).
class LatinToBaybayinView extends StatefulWidget {
  const LatinToBaybayinView({super.key});

  @override
  State<LatinToBaybayinView> createState() => _LatinToBaybayinViewState();
}

class _LatinToBaybayinViewState extends State<LatinToBaybayinView>
    with SingleTickerProviderStateMixin {
  /// One looping 0..1 clock that drives every ambient animation on this
  /// tab (glow border, breathing button, radar rings, scan line).
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  )..repeat();

  // "Did you know?" card: rotates to the next fact every few seconds.
  Timer? _factTimer;
  int _factIndex = 0;

  // DEBUG (evaluation): shows whether each scanned image was saved.
  StreamSubscription<String>? _evalSub;

  // ---- scan state ----
  Uint8List? _image; // the cropped photo that was read
  bool _isLoading = false;
  Map<String, dynamic>? _data; // last successful reply
  String? _message; // shown instead of a result (blurry, nothing found...)
  double _imageWidth = 0;
  double _imageHeight = 0;

  /// Words per text line, in reading order. Each word map has:
  /// word_id, latin, baybayin, syllables [{latin, baybayin}], bbox.
  List<List<Map<String, dynamic>>> _lines = [];

  @override
  void initState() {
    super.initState();
    OfflineRecognizer.warmUp(); // loads the Latin model too (MainActivity)
    if (kSaveEvalCopies) {
      _evalSub = OfflineRecognizer.evalStatus.listen((message) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(message),
            duration: const Duration(seconds: 6),
            backgroundColor: message.contains('FAILED')
                ? Colors.red[700]
                : Colors.green[700],
          ),
        );
      });
    }
    _factTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (mounted) {
        setState(() => _factIndex = (_factIndex + 1) % _facts.length);
      }
    });
  }

  @override
  void dispose() {
    _factTimer?.cancel();
    _evalSub?.cancel();
    _ambient.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Scan flow: camera -> cropper -> Latin recognizer
  // ---------------------------------------------------------------------

  Future<void> _captureFromCamera() async {
    if (AppSettings.instance.hapticsEnabled) HapticFeedback.lightImpact();
    final CameraCaptureResult? captured = await Navigator.of(context)
        .push<CameraCaptureResult>(
          MaterialPageRoute(builder: (_) => const CameraCaptureScreen()),
        );
    if (captured == null || !mounted) return;

    // The Latin side reads one page at a time. If several pages were
    // taken, the first one is used.
    final Uint8List bytes;
    if (captured.isMultiPage) {
      if (captured.pages.isEmpty) return;
      bytes = captured.pages.first;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              'Latin to Baybayin reads one page at a time - using page 1.',
              'Isang pahina lang ang binabasa - ginamit ang pahina 1.',
            ),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
    } else {
      bytes = captured.imageBytes;
    }

    final Uint8List? cropped = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => ImageCropperScreen(imageData: bytes)),
    );
    if (cropped == null || !mounted) return;
    await _process(cropped, inputType: captured.inputType);
  }

  /// [inputType] is the camera's Pen | Marker choice ('pen' or 'marker').
  Future<void> _process(Uint8List bytes, {String inputType = 'pen'}) async {
    setState(() {
      _image = bytes;
      _isLoading = true;
      _data = null;
      _message = null;
      _lines = [];
    });

    final response = await OfflineRecognizer.recognizeLatin(
      bytes,
      inputType: inputType,
    );
    if (!mounted) return;

    final status = response?['status']?.toString();
    setState(() {
      _isLoading = false;
      _imageWidth = readNumber(response, 'image_width');
      _imageHeight = readNumber(response, 'image_height');

      if (response == null) {
        _message = tr(
          'Error: Could not process the image. Please try again.',
          'Error: Hindi maproseso ang larawan. Pakisubukan muli.',
        );
      } else if (status == 'blurry') {
        _message = tr(
          'The photo is too blurry. Hold the phone steady and scan again.',
          'Masyadong malabo ang larawan. Hawakan nang matatag ang phone at '
              'mag-scan muli.',
        );
      } else if (status != 'ok' ||
          (response['translated_text']?.toString() ?? '').isEmpty) {
        _message = tr(
          'No Latin letters found. Write in print (not cursive) and try a '
              'clearer crop.',
          'Walang nakitang titik Latin. Isulat nang naka-print (hindi '
              'kabit-kabit) at subukan ang mas malinaw na crop.',
        );
      } else {
        _data = response;
        _buildLinesFrom(response);
      }
    });

    // Like the Baybayin tab: open the full result screen after a scan.
    if (_data != null) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _openResult(haptic: false);
      });
    }
  }

  /// Opens the full result screen (photo filters, letter boxes, syllable
  /// breakdown, the letters the model read, export) for the last scan.
  void _openResult({bool haptic = true}) {
    final data = _data;
    final image = _image;
    if (_isLoading || data == null || image == null) return;
    if (haptic && AppSettings.instance.hapticsEnabled) {
      HapticFeedback.selectionClick();
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LatinResultScreen(
          sourceImage: image,
          baybayinText: data['translated_text']?.toString() ?? '',
          latinText: data['latin_text']?.toString() ?? '',
          words: [
            for (final w in (data['words'] as List? ?? const []))
              if (w is Map) Map<String, dynamic>.from(w),
          ],
          // The Latin reply lists its letters under 'detections'. Only
          // letters with a box are passed, so a bad entry can't crash it.
          detections: [
            for (final d in (data['detections'] as List? ?? const []))
              if (d is Map && d['bbox'] is Map) Map<String, dynamic>.from(d),
          ],
          imageWidth: readNumber(data, 'image_width'),
          imageHeight: readNumber(data, 'image_height'),
        ),
      ),
    );
  }

  /// Splits the reply's words into text lines, using latin_text's line
  /// breaks (the Python side lists words line by line, left to right).
  void _buildLinesFrom(Map<String, dynamic> data) {
    final words = <Map<String, dynamic>>[
      for (final w in (data['words'] as List? ?? const []))
        if (w is Map) Map<String, dynamic>.from(w),
    ];
    final lineSizes = (data['latin_text']?.toString() ?? '')
        .split('\n')
        .map((l) => l.trim().split(RegExp(r'\s+')).where((s) => s.isNotEmpty))
        .map((l) => l.length)
        .where((n) => n > 0)
        .toList();

    final lines = <List<Map<String, dynamic>>>[];
    var start = 0;
    for (final n in lineSizes) {
      if (start >= words.length) break;
      final end = math.min(start + n, words.length);
      lines.add(words.sublist(start, end));
      start = end;
    }
    if (start < words.length) lines.add(words.sublist(start));
    _lines = lines;
  }

  void _copyResult() {
    final text = _data?['translated_text']?.toString() ?? '';
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    if (AppSettings.instance.hapticsEnabled) HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Copied to clipboard', 'Nakopya na')),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------

  static const Color _amber = DayawColors.amber;
  static const Color _gold = DayawColors.gold;
  static const Color _yellow = DayawColors.yellow;
  static const Color _deepBrown = DayawColors.deepBrown;

  // (icon, English, Filipino)
  static const List<(IconData, String, String)> _tips = [
    (Icons.text_fields, 'Print, not cursive', 'Naka-print, hindi kabit-kabit'),
    (Icons.space_bar, 'Space out letters', 'Paglayuin ang mga titik'),
    (Icons.edit, 'Pick Pen or Marker', 'Piliin ang Pen o Marker'),
    (Icons.description_outlined, 'Plain white paper', 'Payak na puting papel'),
    (Icons.block, 'No C, F, J, Q, V, X, Z', 'Walang C, F, J, Q, V, X, Z'),
    (Icons.wb_sunny_outlined, 'No glare or shadow', 'Walang silaw o anino'),
  ];

  // (Baybayin sample, English, Filipino)
  static const List<(String, String, String)> _facts = [
    (
      'ᜊᜌ᜔ᜊᜌᜒᜈ᜔',
      'Each Baybayin character is a whole syllable: a consonant plus "a".',
      'Bawat karakter ng Baybayin ay isang buong pantig: katinig na may '
          'kasamang "a".',
    ),
    (
      'ᜅ',
      '"NG" is a single letter in Baybayin, so "nga" takes one character.',
      'Iisang titik lang ang "NG" sa Baybayin, kaya isang karakter lang '
          'ang "nga".',
    ),
    (
      'ᜊᜑᜌ᜔',
      '"Bahay" is written ba-ha-y: the cross kudlit silences the final "a".',
      'Isinusulat ang "bahay" bilang ba-ha-y: pinapatay ng krus na kudlit '
          'ang "a" sa dulo.',
    ),
    (
      'ᜃ ᜃᜒ ᜃᜓ',
      'A kudlit above a letter turns its "a" into "e/i"; below, into "o/u".',
      'Ang kudlit sa itaas ng titik ay ginagawang "e/i" ang "a"; sa ibaba, '
          'nagiging "o/u".',
    ),
    (
      'ᜇ',
      'D and R share one letter in Baybayin - context tells them apart.',
      'Iisang titik ang D at R sa Baybayin - ang konteksto ang nagtatangi '
          'sa kanila.',
    ),
  ];

  /// 0..1..0 once per ambient loop - for breathing / pulsing.
  double get _breath => 0.5 - 0.5 * math.cos(2 * math.pi * _ambient.value);

  Color _confidenceColor(double confidence) {
    if (confidence >= 90) return const Color(0xFF5E8B5A);
    if (confidence >= 75) return const Color(0xFFC2873F);
    return const Color(0xFFB35C52);
  }

  @override
  Widget build(BuildContext context) {
    final hasResult = _data != null && !_isLoading;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        _buildHeroHeader(),
        const SizedBox(height: 16),
        _buildScannerCard(),
        const SizedBox(height: 18),
        _buildScanButton(),
        if (hasResult || (_message != null && !_isLoading)) ...[
          const SizedBox(height: 24),
          _buildResultCard(),
        ],
        const SizedBox(height: 28),
        _sectionTitle(
          context.tr('Tips for a perfect scan', 'Mga tip para sa magandang scan'),
          Icons.auto_awesome,
        ),
        const SizedBox(height: 12),
        _buildTips(),
        const SizedBox(height: 28),
        _sectionTitle(
          context.tr('Did you know?', 'Alam mo ba?'),
          Icons.lightbulb_outline,
        ),
        const SizedBox(height: 12),
        _buildFactCard(),
        const SizedBox(height: 24),
        Text(
          context.tr(
            '© 2026 DAYAW. All rights reserved.',
            '© 2026 DAYAW. Nakalaan ang lahat ng karapatan.',
          ),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _sectionTitle(String text, IconData icon) =>
      DayawSectionTitle(text, icon);

  Widget _buildHeroHeader() {
    return DayawHeroHeader(
      title: context.tr(
        'See your handwriting in Baybayin',
        'Tingnan ang sulat-kamay mo sa Baybayin',
      ),
      subtitle: context.tr(
        'Scan handwritten Latin letters and see them in Baybayin in seconds.',
        'I-scan ang sulat-kamay na titik Latin at makita ito sa Baybayin '
            'sa ilang segundo.',
      ),
      baybayin: 'bahay → ᜊᜑᜌ᜔',
      shimmer: _ambient,
    );
  }

  /// The photo (or the empty scanner), framed by a slowly rotating glow.
  Widget _buildScannerCard() {
    final embroidered = DayawTheme.of(context) == DayawTheme.embroidery;
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ambient,
        builder: (context, child) {
          final glow = _isLoading ? 1.0 : 0.35 + 0.35 * _breath;
          return Container(
            height: 300,
            padding: embroidered ? null : const EdgeInsets.all(2.5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              color: embroidered ? const Color(0xFFFFFBF5) : _amber,
              gradient: themedGradient(
                SweepGradient(
                  transform: GradientRotation(2 * math.pi * _ambient.value),
                  colors: const [
                    _yellow,
                    _amber,
                    _gold,
                    _yellow,
                    Color(0xFFB9853A),
                    _gold,
                    _yellow,
                  ],
                ),
              ),
              boxShadow: [
                BoxShadow(
                  color: _yellow.withValues(alpha: 0.3 * glow),
                  blurRadius: 16 + 10 * glow,
                  spreadRadius: glow,
                ),
              ],
            ),
            child: embroidered
                ? CustomPaint(
                    foregroundPainter: const StitchBorderPainter(
                      color: Thread.amber,
                      radius: 26,
                      inset: 7,
                      stitch: 9,
                      gap: 5,
                      width: 2.4,
                    ),
                    child: child,
                  )
                : child,
          );
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(embroidered ? 26 : 23.5),
          child: ColoredBox(
            color: const Color(0xFFFFFBF5),
            child: _image == null ? _buildEmptyScanner() : _buildImageDisplay(),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyScanner() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _captureFromCamera,
      child: AnimatedBuilder(
        animation: _ambient,
        builder: (context, _) => LayoutBuilder(
          builder: (context, constraints) => Stack(
            alignment: Alignment.center,
            children: [
              for (var i = 0; i < 3; i++)
                _radarRing((_ambient.value + i / 3) % 1),
              Container(
                width: 84,
                height: 84,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: _yellow,
                  gradient: themedGradient(
                    const LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [_gold, _yellow, _amber],
                    ),
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x44D9A441),
                      blurRadius: 22,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.document_scanner_outlined,
                  color: _deepBrown,
                  size: 38,
                ),
              ),
              Positioned(
                bottom: 22,
                child: Text(
                  context.tr(
                    'Tap to scan Latin handwriting',
                    'I-tap para i-scan ang sulat Latin',
                  ),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: _deepBrown.withValues(alpha: 0.6 + 0.4 * _breath),
                  ),
                ),
              ),
              _scanLine(constraints.maxHeight, faint: true),
            ],
          ),
        ),
      ),
    );
  }

  Widget _radarRing(double t) {
    final size = 84 + 170 * t;
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: Color.lerp(_yellow, _amber, t)!.withValues(
              alpha: (1 - t) * 0.9,
            ),
            width: 3 - t,
          ),
        ),
      ),
    );
  }

  Widget _scanLine(double height, {bool faint = false}) {
    final t = Curves.easeInOut.transform(
      (_ambient.value * 2) % 1 < 0.5
          ? ((_ambient.value * 2) % 1) * 2
          : 2 - ((_ambient.value * 2) % 1) * 2,
    );
    return Positioned(
      top: t * (height - 4),
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Container(
          height: 3,
          decoration: BoxDecoration(
            color: _amber.withValues(alpha: faint ? 0.75 : 1),
            gradient: themedGradient(
              LinearGradient(
                colors: [
                  _amber.withValues(alpha: 0),
                  _yellow.withValues(alpha: faint ? 0.75 : 1),
                  _gold,
                  _yellow.withValues(alpha: faint ? 0.75 : 1),
                  _amber.withValues(alpha: 0),
                ],
              ),
            ),
            boxShadow: [
              BoxShadow(
                color: _yellow.withValues(alpha: faint ? 0.45 : 0.85),
                blurRadius: 12,
                spreadRadius: 2,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImageDisplay() {
    final words = [for (final line in _lines) ...line];
    final hasBoxes =
        !_isLoading && words.isNotEmpty && _imageWidth > 0 && _imageHeight > 0;
    return Stack(
      children: [
        Center(
          child: Image.memory(
            _image!,
            fit: BoxFit.contain,
            // Only cacheWidth - setting cacheHeight too squashes big photos
            // and the boxes would no longer line up.
            cacheWidth: 1600,
          ),
        ),
        if (hasBoxes)
          Positioned.fill(
            child: CustomPaint(
              painter: _WordBoxPainter(
                imageSize: Size(_imageWidth, _imageHeight),
                words: words,
              ),
            ),
          ),
        if (_isLoading)
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _ambient,
              builder: (context, _) => LayoutBuilder(
                builder: (context, constraints) => Stack(
                  children: [
                    Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black.withValues(alpha: 0.28),
                      ),
                    ),
                    _scanLine(constraints.maxHeight),
                    Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 8,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.6),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: _gold,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                '${context.tr('Reading letters', 'Binabasa ang mga titik')}'
                                '${'.' * (1 + (_ambient.value * 3).floor() % 3)}',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildScanButton() {
    final label = _image == null
        ? context.tr('Scan with Camera', 'I-scan gamit ang Kamera')
        : context.tr('Scan Again', 'Mag-scan Muli');
    return AnimatedBuilder(
      animation: _ambient,
      builder: (context, child) => Transform.scale(
        scale: _isLoading ? 1 : 1 + 0.02 * _breath,
        child: Container(
          height: 58,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(29),
            color: _isLoading ? Colors.grey.shade400 : _yellow,
            gradient: themedGradient(
              LinearGradient(
                begin: Alignment(-1.6 + 1.2 * _breath, 0),
                end: Alignment(1.6 + 1.2 * _breath, 0),
                colors: _isLoading
                    ? [Colors.grey.shade400, Colors.grey.shade500]
                    : const [_amber, _yellow, _gold, _yellow, _amber],
              ),
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: _isLoading ? 0 : 0.7),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(
                  0xFFFFC400,
                ).withValues(alpha: _isLoading ? 0 : 0.2 + 0.15 * _breath),
                blurRadius: 18 + 14 * _breath,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: child,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(29),
          onTap: _isLoading ? null : _captureFromCamera,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.camera_alt_rounded, color: _deepBrown),
              const SizedBox(width: 10),
              Text(
                label,
                style: const TextStyle(
                  color: _deepBrown,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Baybayin result (or a message), with the Latin that was read.
  Widget _buildResultCard() {
    final data = _data;
    if (data == null) {
      return GlassContainer(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const Icon(Icons.info_outline, color: Color(0xFFC2873F)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _message ?? '',
                style: const TextStyle(fontSize: 14, color: Colors.black87),
              ),
            ),
          ],
        ),
      );
    }

    final baybayin = data['translated_text']?.toString() ?? '';
    final latin = data['latin_text']?.toString() ?? '';
    final confidence = readNumber(data, 'confidence');
    final color = _confidenceColor(confidence);
    final letters = (data['detections'] as List? ?? const []).length;
    final words = [for (final l in _lines) ...l].length;

    return TweenAnimationBuilder<double>(
      key: ValueKey(identityHashCode(data)),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, 24 * (1 - t)),
          child: child,
        ),
      ),
      child: GlassContainer(
        padding: const EdgeInsets.all(18),
        tint: const Color(0xA6FFF4B8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: _yellow,
                    gradient: themedGradient(
                      const LinearGradient(colors: [_gold, _yellow, _amber]),
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(color: Color(0x33D9A441), blurRadius: 8),
                    ],
                  ),
                  child: Text(
                    context.tr('IN BAYBAYIN', 'SA BAYBAYIN'),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                      color: Colors.black87,
                    ),
                  ),
                ),
                const Spacer(),
                if (confidence > 0) _confidenceRing(confidence, color),
              ],
            ),
            const SizedBox(height: 12),
            SelectableText(
              baybayin,
              style: const TextStyle(
                fontFamily: 'BaybayinCustom',
                fontSize: 32,
                color: _deepBrown,
                height: 1.5,
                letterSpacing: 3.0,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '${context.tr('Read as', 'Nabasa bilang')}: $latin',
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: Colors.brown,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _statChip(
                  Icons.text_fields,
                  context.tr('$letters letters', '$letters titik'),
                ),
                _statChip(
                  Icons.short_text,
                  context.tr(
                    '$words ${words == 1 ? 'word' : 'words'}',
                    '$words salita',
                  ),
                ),
                _statChip(
                  Icons.format_list_numbered,
                  context.tr(
                    '${_lines.length} ${_lines.length == 1 ? 'line' : 'lines'}',
                    '${_lines.length} linya',
                  ),
                ),
                _statChip(
                  Icons.offline_bolt_outlined,
                  context.tr('On-device', 'Sa device'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: baybayin.isEmpty ? null : _copyResult,
                style: FilledButton.styleFrom(
                  backgroundColor: _deepBrown,
                  foregroundColor: _yellow,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(
                  context.tr('Copy Baybayin', 'Kopyahin ang Baybayin'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _openResult,
                style: OutlinedButton.styleFrom(
                  foregroundColor: _deepBrown,
                  side: BorderSide(color: _deepBrown.withValues(alpha: 0.5)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.grid_view_rounded, size: 18),
                label: Text(
                  context.tr(
                    'View letter breakdown',
                    'Tingnan ang bawat titik',
                  ),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _confidenceRing(double confidence, Color color) {
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
        color: _yellow.withValues(alpha: 0.45),
        gradient: themedGradient(
          LinearGradient(
            colors: [
              _yellow.withValues(alpha: 0.55),
              _gold.withValues(alpha: 0.35),
            ],
          ),
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _amber.withValues(alpha: 0.5)),
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
              color: _deepBrown,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Tips + facts (same look as the Baybayin to Latin tab)
  // ---------------------------------------------------------------------

  Widget _buildTips() {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: _tips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final (icon, en, fil) = _tips[i];
          return Container(
            width: 112,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              color: Colors.white.withValues(alpha: 0.7),
              gradient: themedGradient(
                LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Colors.white.withValues(alpha: 0.7),
                    _gold.withValues(alpha: 0.45),
                  ],
                ),
              ),
              border: Border.all(color: _yellow.withValues(alpha: 0.6)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33D9A441),
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _deepBrown,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: _gold, size: 18),
                ),
                const Spacer(),
                Text(
                  context.tr(en, fil),
                  maxLines: 2,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: _deepBrown,
                    height: 1.15,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildFactCard() {
    final (sample, factEn, factFil) = _facts[_factIndex];
    final fact = context.tr(factEn, factFil);
    return GestureDetector(
      onTap: () =>
          setState(() => _factIndex = (_factIndex + 1) % _facts.length),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          color: _deepBrown,
          gradient: themedGradient(
            const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [_deepBrown, Color(0xFF6D4C41), Color(0xFF8A6A4A)],
              stops: [0, 0.6, 1],
            ),
          ),
          border: Border.all(color: _yellow.withValues(alpha: 0.7), width: 1.5),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33D9A441),
              blurRadius: 22,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.08, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: Row(
                key: ValueKey(_factIndex),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 84,
                    child: Text(
                      sample,
                      style: const TextStyle(
                        fontFamily: 'BaybayinCustom',
                        fontSize: 28,
                        color: _gold,
                        height: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      fact,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                for (var i = 0; i < _facts.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.only(right: 6),
                    width: i == _factIndex ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _factIndex
                          ? _gold
                          : Colors.white.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                const Spacer(),
                Text(
                  context.tr('Tap for next', 'I-tap para sa susunod'),
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// One green box per WORD over an Image.memory(fit: BoxFit.contain),
/// labelled with the Latin word that was read. Same letterbox math as
/// the Baybayin tab's painter.
class _WordBoxPainter extends CustomPainter {
  final Size imageSize; // pixel size the backend's boxes are in
  final List<Map<String, dynamic>> words;

  _WordBoxPainter({required this.imageSize, required this.words});

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return;
    final FittedSizes fitted = applyBoxFit(BoxFit.contain, imageSize, size);
    final dest = fitted.destination;
    final offsetX = (size.width - dest.width) / 2;
    final offsetY = (size.height - dest.height) / 2;
    final scaleX = dest.width / imageSize.width;
    final scaleY = dest.height / imageSize.height;

    final boxPaint = Paint()
      ..color = const Color(0xFF00E676)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;

    for (final w in words) {
      final bbox = w['bbox'];
      if (bbox is! Map) continue;
      final x0 = (bbox['x0'] as num?)?.toDouble();
      final y0 = (bbox['y0'] as num?)?.toDouble();
      final x1 = (bbox['x1'] as num?)?.toDouble();
      final y1 = (bbox['y1'] as num?)?.toDouble();
      if (x0 == null || y0 == null || x1 == null || y1 == null) continue;

      final rect = Rect.fromLTRB(
        offsetX + x0 * scaleX,
        offsetY + y0 * scaleY,
        offsetX + x1 * scaleX,
        offsetY + y1 * scaleY,
      ).inflate(3);
      canvas.drawRect(rect, boxPaint);

      final label = TextPainter(
        text: TextSpan(
          text: w['latin']?.toString() ?? '',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
            backgroundColor: Color(0xCC000000),
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(
        canvas,
        Offset(rect.left, (rect.top - label.height).clamp(0, size.height)),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _WordBoxPainter oldDelegate) =>
      oldDelegate.words != words || oldDelegate.imageSize != imageSize;
}