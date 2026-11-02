import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show applyBoxFit, FittedSizes;
import 'package:flutter/services.dart';
import '../services/app_language.dart';
import '../services/haptics.dart';
import '../services/offline_recognizer.dart';
import '../services/recognition_outcome.dart';
import '../widgets/image_cropper_widget.dart';
import '../screens/camera_capture_screen.dart';
import '../screens/latin_result_screen.dart';
import '../widgets/dayaw_style.dart';
import '../widgets/glass.dart';
import '../widgets/scan_beam.dart';

/// Handles the "Latin to Baybayin" mode: take a photo of HANDWRITTEN Latin
/// (printed letters), crop it, read every letter on the phone with the
/// Latin SVM, and show the Baybayin.
///
/// Replaces the old typed "Filipino to Baybayin" mode. The class keeps its
/// old name (TagalogToBaybayinView) so the tab that opens it does not have
/// to change - only the label on the tab should now say "Latin → Baybayin".
///
/// Multi-page scans work like the Baybayin to Latin tab: each page is
/// cropped and read in turn, and LatinMultiPageResultScreen lists them.
///
/// Same look as the Baybayin to Latin tab: shimmering hero header, a
/// glowing scanner card with word boxes, a pop-in result card with a
/// confidence ring, writing tips and rotating Baybayin facts. The
/// syllable and letter breakdowns are on LatinResultScreen, which opens
/// after a scan (like BaybayinResultScreen on the other tab).
class LatinToBaybayinView extends StatefulWidget {
  const LatinToBaybayinView({super.key, this.header});

  /// Shown at the top in place of this view's own header, so a parent
  /// page (the combined Recognize page) can share one header.
  final Widget? header;

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

  // Multi-page scan (same as the Baybayin to Latin tab): every page and its
  // reply, in order. Empty for a normal single-photo scan.
  List<LatinScannedPage> _pages = [];
  bool get _isMultiPage => _pages.length > 1;

  // Shown in the loading pill instead of "Reading letters" (which page).
  String? _loadingLabel;

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
                ? DayawColors.brick
                : DayawColors.leaf,
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
    Haptics.light();
    final CameraCaptureResult? captured = await Navigator.of(context)
        .push<CameraCaptureResult>(
          MaterialPageRoute(builder: (_) => const CameraCaptureScreen()),
        );
    if (captured == null || !mounted) return;

    // Several pages: crop and read each one (like the Baybayin tab).
    if (captured.isMultiPage) {
      await _processPages(captured.pages, inputType: captured.inputType);
      return;
    }
    final Uint8List bytes = captured.imageBytes;

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
      _pages = [];
      _loadingLabel = null;
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

  /// Multi-page scan: every page is opened in the cropper one by one
  /// (page 1, crop, Apply -> page 2, crop, Apply ...). Then the pages are
  /// read one after another (the on-phone recognizer handles one image at
  /// a time) and shown together. Closing the cropper skips that page.
  Future<void> _processPages(
    List<Uint8List> allPages, {
    required String inputType,
  }) async {
    if (allPages.isEmpty) return;
    final capturedPages = allPages.take(CameraCaptureScreen.maxPages).toList();

    // ---- Step 1: crop each page, one at a time ----
    final cropped = <Uint8List>[];
    var skipped = 0;
    for (var i = 0; i < capturedPages.length; i++) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              tr(
                'Crop page ${i + 1} of ${capturedPages.length}',
                'I-crop ang pahina ${i + 1} ng ${capturedPages.length}',
              ),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      final Uint8List? page = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(
          builder: (_) => ImageCropperScreen(imageData: capturedPages[i]),
        ),
      );
      if (page == null) {
        skipped++; // closed the cropper -> skip this page
      } else {
        cropped.add(page);
      }
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    if (cropped.isEmpty) return; // every page was skipped
    if (skipped > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              '$skipped ${skipped == 1 ? 'page was' : 'pages were'} skipped.',
              'Nilaktawan ang $skipped pahina.',
            ),
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }

    // ---- Step 2: read the cropped pages ----
    setState(() {
      _image = cropped.first;
      _isLoading = true;
      _data = null;
      _message = null;
      _lines = [];
      _pages = [];
    });

    final scanned = <LatinScannedPage>[];
    for (var i = 0; i < cropped.length; i++) {
      setState(() {
        // Show the page that is being read right now (page 2 of 10 shows
        // the 2nd photo, page 3 the 3rd ...), not always the first one.
        _image = cropped[i];
        _loadingLabel = tr(
          'Reading page ${i + 1} of ${cropped.length}',
          'Binabasa ang pahina ${i + 1} ng ${cropped.length}',
        );
      });
      // One bad page must not sink the whole scan: it is kept as an
      // unread page (marked on the results screen) and the rest carry on.
      Map<String, dynamic>? response;
      try {
        response = await OfflineRecognizer.recognizeLatin(
          cropped[i],
          inputType: inputType,
        );
      } catch (_) {
        response = null;
      }
      if (!mounted) return;
      scanned.add(LatinScannedPage(cropped[i], response));
    }

    final unread = scanned.where((p) => !p.isRead).length;
    if (unread > 0 && unread < scanned.length) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            tr(
              '$unread of ${scanned.length} pages could not be read. '
                  'They are marked on the results screen.',
              'Hindi nabasa ang $unread sa ${scanned.length} pahina. '
                  'Nakamarka ang mga ito sa resulta.',
            ),
          ),
          duration: const Duration(seconds: 4),
        ),
      );
    }

    final read = scanned.where((p) => p.isRead).toList();
    setState(() {
      _isLoading = false;
      _loadingLabel = null;
      _pages = scanned;
      // The scanner card shows the first page, with its own word boxes.
      final first = scanned.first;
      _image = first.image;
      _imageWidth = readNumber(first.data, 'image_width');
      _imageHeight = readNumber(first.data, 'image_height');
      _lines = first.isRead ? _linesOf(first.data!) : [];
      if (read.isEmpty) {
        _message = tr(
          'No Latin letters found on any page. Write in print (not cursive) '
              'and try clearer photos.',
          'Walang nakitang titik Latin sa anumang pahina. Isulat nang '
              'naka-print (hindi kabit-kabit) at subukan ang mas malinaw na '
              'larawan.',
        );
      } else {
        _data = {
          'status': 'ok',
          'translated_text': LatinScannedPage.combinedBaybayin(scanned),
          'latin_text': LatinScannedPage.combinedLatin(scanned),
          'confidence': LatinScannedPage.combinedConfidence(scanned),
        };
      }
    });

    if (_data != null) {
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _openResult(haptic: false);
      });
    }
  }

  /// Opens the full result screen (photo filters, letter boxes, syllable
  /// breakdown, the letters the model read, export) for the last scan.
  /// After a multi-page scan it opens the list of pages instead.
  void _openResult({bool haptic = true}) {
    final data = _data;
    final image = _image;
    if (_isLoading || data == null || image == null) return;
    if (haptic) Haptics.selection();
    if (_isMultiPage) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => LatinMultiPageResultScreen(pages: _pages),
        ),
      );
      return;
    }
    openLatinResult(context, image, data);
  }

  /// Splits the reply's words into text lines, using latin_text's line
  /// breaks (the Python side lists words line by line, left to right).
  void _buildLinesFrom(Map<String, dynamic> data) => _lines = _linesOf(data);

  static List<List<Map<String, dynamic>>> _linesOf(Map<String, dynamic> data) {
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
    return lines;
  }

  void _copyResult() {
    final text = _data?['translated_text']?.toString() ?? '';
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    Haptics.light();
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

  static Color get _amber => DayawColors.amber;
  static Color get _yellow => DayawColors.yellow;
  static Color get _deepBrown => DayawColors.text;

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

  Color _confidenceColor(double confidence) {
    if (confidence >= 90) return DayawColors.leaf;
    if (confidence >= 75) return DayawColors.amber;
    return DayawColors.brick;
  }

  @override
  Widget build(BuildContext context) {
    final hasResult = _data != null && !_isLoading;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        widget.header ?? _buildHeroHeader(),
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
          style: TextStyle(fontSize: 11, color: DayawColors.textMuted),
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
      shimmer: _ambient,
    );
  }

  /// The photo (or the empty scanner) in a sunken well, set in a raised
  /// neumorphic frame whose yellow rim breathes while it reads.
  Widget _buildScannerCard() {
    DayawTheme.of(context);
    return RepaintBoundary(
      child: Container(
        height: 280,
        padding: const EdgeInsets.all(10),
        // Raised frame, the well pressed into it; the well's rim turns
        // yellow while a scan is being read.
        decoration: neuRaised(borderRadius: BorderRadius.circular(30)),
        foregroundDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          border: _isLoading
              ? Border.all(color: _yellow.withValues(alpha: 0.7), width: 1.5)
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(22),
          child: DecoratedBox(
            decoration: neuSunken(borderRadius: BorderRadius.circular(22)),
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
      // Empty state: viewfinder corners and a gliding scan beam behind a
      // raised round icon and a hint. Tap anywhere to scan.
      child: Stack(
        fit: StackFit.expand,
        children: [
          ScanBeam(animation: _ambient),
          Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
              Container(
                width: 68,
                height: 68,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: DayawColors.bg,
                  boxShadow: neuShadows(depth: 0.6),
                ),
                child: Icon(
                  Icons.document_scanner_outlined,
                  color: DayawColors.amber,
                  size: 28,
                ),
              ),
              const SizedBox(height: 14),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  context.tr(
                    'Tap to scan Latin handwriting',
                    'I-tap para i-scan ang sulat Latin',
                  ),
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: DayawColors.textMuted,
                  ),
                ),
              ),
        ],
          ),
        ],
      ),
    );
  }

  /// The loading sweep: the shared scan beam, brighter.
  Widget _scanLine(double height, {bool faint = false}) =>
      Positioned.fill(
        child: ScanBeam(
          animation: _ambient,
          strong: !faint,
          corners: false,
        ),
      );

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
                                  color: DayawColors.sun,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Text(
                                '${_loadingLabel ?? context.tr('Reading letters', 'Binabasa ang mga titik')}'
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
    // Flat yellow key with a soft lift; sinks into the ground while busy.
    return Container(
      height: 54,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(27),
        color: _isLoading ? DayawColors.well : DayawColors.sun,
        boxShadow: _isLoading ? null : neuShadows(depth: 0.5),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(27),
          onTap: _isLoading ? null : _captureFromCamera,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.camera_alt_rounded,
                color: _isLoading ? DayawColors.textMuted : DayawColors.onSun,
              ),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  color: _isLoading ? DayawColors.textMuted : DayawColors.onSun,
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
            Icon(Icons.info_outline, color: DayawColors.amber),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _message ?? '',
                style: TextStyle(fontSize: 14, color: DayawColors.text),
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
    // Counts over every page of a multi-page scan.
    final pageData = _isMultiPage
        ? [for (final p in _pages) if (p.isRead) p.data!]
        : [data];
    final pageLines = [for (final d in pageData) _linesOf(d)];
    final letters = pageData.fold<int>(
      0,
      (n, d) => n + (d['detections'] as List? ?? const []).length,
    );
    final words = pageLines.fold<int>(
      0,
      (n, ls) => n + [for (final l in ls) ...l].length,
    );
    final lineCount = pageLines.fold<int>(0, (n, ls) => n + ls.length);

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
                    border: Border.all(color: DayawColors.line),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    context.tr('IN BAYBAYIN', 'SA BAYBAYIN'),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                      color: DayawColors.amber,
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
              style: TextStyle(
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
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: DayawColors.textMuted,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_isMultiPage)
                  _statChip(
                    Icons.auto_stories_outlined,
                    context.tr(
                      '${_pages.length} pages',
                      '${_pages.length} pahina',
                    ),
                  ),
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
                    '$lineCount ${lineCount == 1 ? 'line' : 'lines'}',
                    '$lineCount linya',
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
                  backgroundColor: DayawColors.charcoal,
                  foregroundColor: DayawColors.sun,
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
                  side: BorderSide(color: DayawColors.line, width: 1.2),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.grid_view_rounded, size: 18),
                label: Text(
                  _isMultiPage
                      ? context.tr(
                          'View all pages',
                          'Tingnan ang lahat ng pahina',
                        )
                      : context.tr(
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
      decoration: neuSunken(borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: _amber),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
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
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: _tips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (icon, en, fil) = _tips[i];
          // A small flat chip: icon + one line of advice.
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: neuSunken(borderRadius: BorderRadius.circular(19)),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: DayawColors.amber, size: 16),
                const SizedBox(width: 6),
                Text(
                  context.tr(en, fil),
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: _deepBrown,
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
        decoration: neuSunken(borderRadius: BorderRadius.circular(20)),
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
                      style: TextStyle(
                        fontFamily: 'BaybayinCustom',
                        fontSize: 24,
                        color: DayawColors.amber,
                        height: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      fact,
                      style: TextStyle(
                        color: DayawColors.text,
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
                          ? DayawColors.sun
                          : DayawColors.line,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                const Spacer(),
                Text(
                  context.tr('Tap for next', 'I-tap para sa susunod'),
                  style: TextStyle(
                    fontSize: 11,
                    color: DayawColors.textMuted,
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
      ..color = DayawColors.sun
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
            color: DayawColors.sun,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            backgroundColor: Color(0xE01E1C19),
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

/// Opens LatinResultScreen (photo, letter boxes, syllable and letter
/// breakdown) for ONE page's reply.
void openLatinResult(
  BuildContext context,
  Uint8List image,
  Map<String, dynamic> data,
) {
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

/// One page of a multi-page Latin scan: the cropped photo and the
/// recognizer's reply (null when the page could not be processed).
class LatinScannedPage {
  LatinScannedPage(this.image, this.response);

  final Uint8List image;
  final Map<String, dynamic>? response;

  /// The reply, only when the page was read (status ok, with Baybayin).
  Map<String, dynamic>? get data => isRead ? response : null;

  bool get isRead =>
      response != null &&
      response!['status']?.toString() == 'ok' &&
      (response!['translated_text']?.toString() ?? '').isNotEmpty;

  /// Why a page could not be read (shown on its card).
  String get problem {
    final r = response;
    if (r == null) {
      return tr('This page could not be processed.',
          'Hindi naproseso ang pahinang ito.');
    }
    if (r['status']?.toString() == 'blurry') {
      return tr('This page is too blurry.', 'Masyadong malabo ang pahinang ito.');
    }
    return tr('No Latin letters found on this page.',
        'Walang nakitang titik Latin sa pahinang ito.');
  }

  static String combinedBaybayin(List<LatinScannedPage> pages) => pages
      .where((p) => p.isRead)
      .map((p) => p.data!['translated_text'].toString().trim())
      .join('\n\n');

  static String combinedLatin(List<LatinScannedPage> pages) => pages
      .where((p) => p.isRead)
      .map((p) => (p.data!['latin_text']?.toString() ?? '').trim())
      .join('\n\n');

  /// Average confidence of the pages that were read.
  static double combinedConfidence(List<LatinScannedPage> pages) {
    final values = [
      for (final p in pages)
        if (p.isRead) readNumber(p.data, 'confidence'),
    ].where((v) => v > 0).toList();
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }
}

/// Every page of a multi-page Latin scan, in order. Tap a page to open its
/// full result (letter boxes, syllable and letter breakdown).
class LatinMultiPageResultScreen extends StatelessWidget {
  const LatinMultiPageResultScreen({super.key, required this.pages});

  final List<LatinScannedPage> pages;

  void _copyAll(BuildContext context) {
    final text = LatinScannedPage.combinedBaybayin(pages);
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
    Haptics.light();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Copied to clipboard', 'Nakopya na')),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final readCount = pages.where((p) => p.isRead).length;
    return Scaffold(
      backgroundColor: DayawColors.bg,
      appBar: AppBar(
        backgroundColor: DayawColors.bg,
        foregroundColor: DayawColors.text,
        elevation: 0,
        title: Text(
          context.tr('${pages.length} pages', '${pages.length} pahina'),
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          if (readCount > 0)
            IconButton(
              tooltip: context.tr('Copy all Baybayin', 'Kopyahin lahat'),
              icon: const Icon(Icons.copy_rounded),
              onPressed: () => _copyAll(context),
            ),
        ],
      ),
      body: ListView.separated(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        itemCount: pages.length,
        separatorBuilder: (_, _) => const SizedBox(height: 14),
        itemBuilder: (context, i) => _pageCard(context, i, pages[i]),
      ),
    );
  }

  /// A read page gets the same yellow-washed card as a result; an unread
  /// page a plain one.
  Widget _cardFrame({required bool read, required Widget child}) => read
      ? GlassContainer(
          padding: const EdgeInsets.all(14),
          tint: const Color(0xA6FFF4B8),
          child: child,
        )
      : GlassContainer(padding: const EdgeInsets.all(14), child: child);

  Widget _pageCard(BuildContext context, int index, LatinScannedPage page) {
    final data = page.data;
    final confidence = data == null ? 0.0 : readNumber(data, 'confidence');
    return GestureDetector(
      onTap: data == null
          ? null
          : () {
              Haptics.selection();
              openLatinResult(context, page.image, data);
            },
      child: _cardFrame(
        read: data != null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.memory(
                page.image,
                width: 84,
                height: 84,
                fit: BoxFit.cover,
                cacheWidth: 300,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        context.tr('PAGE ${index + 1}', 'PAHINA ${index + 1}'),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1,
                          color: DayawColors.amber,
                        ),
                      ),
                      const Spacer(),
                      if (confidence > 0)
                        Text(
                          '${confidence.round()}%',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            color: confidence >= 90
                                ? DayawColors.leaf
                                : confidence >= 75
                                    ? DayawColors.amber
                                    : DayawColors.brick,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (data == null)
                    Row(
                      children: [
                        Icon(Icons.warning_amber_rounded,
                            size: 16, color: DayawColors.brick),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            page.problem,
                            style: TextStyle(
                              fontSize: 13,
                              color: DayawColors.text,
                            ),
                          ),
                        ),
                      ],
                    )
                  else ...[
                    Text(
                      data['translated_text']?.toString() ?? '',
                      style: TextStyle(
                        fontFamily: 'BaybayinCustom',
                        fontSize: 22,
                        color: DayawColors.text,
                        height: 1.4,
                        letterSpacing: 2.0,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${context.tr('Read as', 'Nabasa bilang')}: '
                      '${data['latin_text'] ?? ''}',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: DayawColors.textMuted,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      context.tr('Tap to see the letters',
                          'I-tap para makita ang mga titik'),
                      style: TextStyle(
                        fontSize: 11,
                        color: DayawColors.textMuted,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}