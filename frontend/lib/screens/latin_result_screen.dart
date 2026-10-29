import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../services/app_language.dart';
import '../services/app_settings.dart';
import '../services/haptics.dart';
import '../services/recognition_outcome.dart';
import '../services/result_exporter.dart';
import '../widgets/dayaw_style.dart';
import '../widgets/glass.dart';
import '../widgets/liquid_glass_selector.dart';

/// Full-screen results view for the Latin-to-Baybayin flow - the same
/// layout as BaybayinResultScreen: the photo (Raw / Black and White / HOG,
/// with letter boxes and pinch-to-zoom), the Baybayin result, a syllable
/// breakdown (Baybayin over Latin), and the letters the model read (the
/// exact 56x56 image the Latin SVM classified, with its letter).
class LatinResultScreen extends StatefulWidget {
  final Uint8List sourceImage;

  /// Baybayin output (the reply's 'translated_text').
  final String baybayinText;

  /// The Latin letters that were read (the reply's 'latin_text', one text
  /// line per line of handwriting).
  final String latinText;

  /// The reply's 'words': word_id, latin, baybayin, syllables, bbox.
  final List<Map<String, dynamic>> words;

  /// The reply's 'detections': one per letter - char, confidence, bbox,
  /// processed_image, word_id.
  final List<Map<String, dynamic>> detections;

  // The backend's image size that the bboxes are measured in.
  final double imageWidth;
  final double imageHeight;

  const LatinResultScreen({
    super.key,
    required this.sourceImage,
    required this.baybayinText,
    required this.latinText,
    required this.words,
    required this.detections,
    required this.imageWidth,
    required this.imageHeight,
  });

  @override
  State<LatinResultScreen> createState() => _LatinResultScreenState();
}

class _LatinResultScreenState extends State<LatinResultScreen> {
  static const String _rawFilter = 'Raw';
  static const String _blackWhiteFilter = 'Black and White';
  static const String _hogFilter = 'HOG';

  static const List<String> _filters = [
    _rawFilter,
    _blackWhiteFilter,
    _hogFilter,
  ];

  // Starting filter / bounding boxes / confidence cut-off come from Settings.
  String _selectedFilter = _filters.contains(AppSettings.instance.resultFilter)
      ? AppSettings.instance.resultFilter
      : _hogFilter;
  bool _showBoundingBoxes = AppSettings.instance.showBoundingBoxesByDefault;
  final double _minConfidence = AppSettings.instance.minConfidence;

  /// Words per text line, in reading order.
  List<List<Map<String, dynamic>>> _lines = const [];

  /// Indexes into widget.detections, grouped by word_id.
  Map<int, List<int>> _lettersByWord = const {};

  // One image per detection (same order as widget.detections), per filter.
  // HOG = the 56x56 image the model saw; Raw / Black and White = the
  // letter cut out of the photo. Built in a background isolate and cached.
  final Map<String, List<Uint8List?>> _letterImagesByFilter = {};
  List<Uint8List?> _letterImages = const [];

  // Filtered versions of the full source image, keyed by filter.
  final Map<String, Uint8List> _filteredSourceImages = {};
  final Set<String> _pendingFilters = {};

  // Pinch-to-zoom on the source image. While zoomed in, the page stops
  // scrolling so one-finger drags pan the image instead.
  final TransformationController _zoomController = TransformationController();
  bool _isZoomed = false;
  int _imagePointers = 0;

  // Which syllable has the Baybayin reference chart open, if any.
  ({int line, int index})? _chartOpenFor;
  final TransformationController _chartZoomController =
      TransformationController();
  bool _isChartZoomed = false;

  static const Color _accentColor = DayawColors.sun;
  static const Duration _uiAnimationDuration = Duration(milliseconds: 220);

  @override
  void initState() {
    super.initState();
    _buildLines();
    // The HOG view only base64-decodes the backend's crops, which is cheap
    // enough to do right away. Raw / Black and White decode the whole
    // photo, so they load in the background.
    if (_selectedFilter == _hogFilter) {
      _letterImages = _buildLetterImages(_letterImagesRequest(_hogFilter));
      _letterImagesByFilter[_hogFilter] = _letterImages;
    } else {
      _loadLetterImages(_selectedFilter);
    }
    _loadFilteredSourceImage(_selectedFilter);
    _zoomController.addListener(_onZoomChanged);
    _chartZoomController.addListener(_onChartZoomChanged);
  }

  @override
  void dispose() {
    _zoomController.dispose();
    _chartZoomController.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------
  // Data
  // ---------------------------------------------------------------------

  /// Splits the words into text lines using latin_text's line breaks
  /// (the Python side lists words line by line, left to right), and
  /// groups the letters by word.
  void _buildLines() {
    final words = widget.words;
    final lineSizes = widget.latinText
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

    final byWord = <int, List<int>>{};
    for (var i = 0; i < widget.detections.length; i++) {
      final id = (widget.detections[i]['word_id'] as num?)?.toInt() ?? -1;
      byWord.putIfAbsent(id, () => []).add(i);
    }
    _lettersByWord = byWord;
  }

  _LetterImagesRequest _letterImagesRequest(String filter) =>
      _LetterImagesRequest(
        detections: widget.detections,
        sourceImage: widget.sourceImage,
        imageWidth: widget.imageWidth,
        imageHeight: widget.imageHeight,
        filter: filter,
      );

  Future<void> _loadLetterImages(String filter) async {
    final cached = _letterImagesByFilter[filter];
    if (cached != null) {
      setState(() => _letterImages = cached);
      return;
    }
    // Type written out: with compute() Dart can't always work it out.
    final List<Uint8List?> images = await compute(
      _buildLetterImages,
      _letterImagesRequest(filter),
    );
    if (!mounted) return;
    _letterImagesByFilter[filter] = images;
    // Only show it if the user hasn't moved on to another filter meanwhile.
    if (filter == _selectedFilter) setState(() => _letterImages = images);
  }

  Future<void> _loadFilteredSourceImage(String filter) async {
    if (filter == _rawFilter ||
        _filteredSourceImages.containsKey(filter) ||
        !_pendingFilters.add(filter)) {
      return;
    }
    final bytes = await compute(
      filter == _hogFilter ? _hogVisualizationPng : _blackAndWhitePng,
      widget.sourceImage,
    );
    if (!mounted) return;
    setState(() {
      _pendingFilters.remove(filter);
      _filteredSourceImages[filter] = bytes;
    });
  }

  void _selectFilter(String filter) {
    if (filter == _selectedFilter) return;
    setState(() => _selectedFilter = filter);
    _loadLetterImages(filter);
    _loadFilteredSourceImage(filter);
  }

  double get _averageConfidence {
    final values = widget.detections
        .map((d) => readNumber(d, 'confidence'))
        .whereType<double>()
        .toList();
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  // ---------------------------------------------------------------------
  // Zoom
  // ---------------------------------------------------------------------

  void _onZoomChanged() {
    final zoomed = _zoomController.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _isZoomed) setState(() => _isZoomed = zoomed);
  }

  void _onChartZoomChanged() {
    final zoomed = _chartZoomController.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _isChartZoomed) setState(() => _isChartZoomed = zoomed);
  }

  void _resetZoom() => _zoomController.value = Matrix4.identity();

  void _updateImagePointers(int delta) {
    final wasPinching = _imagePointers >= 2;
    _imagePointers = math.max(0, _imagePointers + delta);
    if ((_imagePointers >= 2) != wasPinching) setState(() {});
  }

  bool get _lockPageScroll =>
      _isZoomed || _isChartZoomed || _imagePointers >= 2;

  // ---------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------

  Color _confidenceColor(double conf) {
    if (conf >= 90.0) return DayawColors.leaf;
    if (conf >= 80.0) return DayawColors.amber;
    if (conf >= 70.0) return DayawColors.brick;
    return DayawColors.textMuted;
  }

  void _copy(String text) {
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

  /// On-screen name of a filter (the filter keys themselves stay English).
  static String _filterLabel(String filter) => switch (filter) {
    _rawFilter => tr('Raw', 'Orihinal'),
    _blackWhiteFilter => tr('Black and White', 'Itim at Puti'),
    _ => filter,
  };

  // ---------------------------------------------------------------------
  // Export (same sheet and formats as the Baybayin result screen)
  // ---------------------------------------------------------------------

  bool _isExporting = false;

  // (format, icon, English description, Filipino description)
  static const List<(ExportFormat, IconData, String, String)> _exportOptions = [
    (
      ExportFormat.jpg,
      Icons.image_outlined,
      'Saves to Gallery, small file size',
      'Ise-save sa Gallery, maliit na file',
    ),
    (
      ExportFormat.png,
      Icons.photo_outlined,
      'Saves to Gallery, sharpest quality',
      'Ise-save sa Gallery, pinakamalinaw',
    ),
    (
      ExportFormat.pdf,
      Icons.picture_as_pdf_outlined,
      'Document for printing',
      'Dokumento para i-print',
    ),
    (ExportFormat.txt, Icons.notes_rounded, 'Plain text only', 'Teksto lamang'),
  ];

  Future<void> _openExportSheet() async {
    Haptics.selection();
    final format = await showModalBottomSheet<ExportFormat>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GlassContainer(
            tint: const Color(0xE6FFFBF5),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DayawSectionTitle(
                  context.tr('Export result', 'I-export ang resulta'),
                  Icons.ios_share,
                ),
                const SizedBox(height: 4),
                Text(
                  context.tr(
                    'Includes the image with the current filter, the result '
                        'and the letter breakdown.',
                    'Kasama ang larawan sa kasalukuyang filter, ang resulta '
                        'at ang bawat titik.',
                  ),
                  style: TextStyle(fontSize: 12.5, color: DayawColors.textMuted),
                ),
                const SizedBox(height: 10),
                for (final (format, icon, descEn, descFil) in _exportOptions)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    leading: Container(
                      width: 38,
                      height: 38,
                      decoration: BoxDecoration(
                        color: DayawColors.charcoal,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(icon, color: DayawColors.sun, size: 20),
                    ),
                    title: Text(
                      format.label,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: DayawColors.text,
                      ),
                    ),
                    subtitle: Text(
                      context.tr(descEn, descFil),
                      style: TextStyle(color: DayawColors.textMuted),
                    ),
                    trailing: Icon(
                      format.savesToGallery
                          ? Icons.download_rounded
                          : Icons.chevron_right,
                      color: DayawColors.textMuted,
                    ),
                    onTap: () => Navigator.of(context).pop(format),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (format != null) await _export(format);
  }

  Future<void> _export(ExportFormat format) async {
    setState(() => _isExporting = true);
    try {
      await ResultExporter.export(await _collectExport(), format);
      if (mounted && format.savesToGallery) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                '${format.label} saved to Gallery (${ResultExporter.galleryAlbum} album)',
                'Na-save ang ${format.label} sa Gallery (album na ${ResultExporter.galleryAlbum})',
              ),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr(
                'Could not export ${format.label}: $e',
                'Hindi ma-export ang ${format.label}: $e',
              ),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  /// Snapshot of what's on screen: the selected filter's image (and
  /// boxes, if shown), the result and that filter's letter breakdown.
  Future<ResultExport> _collectExport() async {
    final filter = _selectedFilter;

    Uint8List image = widget.sourceImage;
    if (filter != _rawFilter) {
      image =
          _filteredSourceImages[filter] ??
          await compute(
            filter == _hogFilter ? _hogVisualizationPng : _blackAndWhitePng,
            widget.sourceImage,
          );
    }

    // Type written out: with ?? and compute() Dart can't work it out.
    final List<Uint8List?> letterImages =
        _letterImagesByFilter[filter] ??
        await compute(_buildLetterImages, _letterImagesRequest(filter));

    final boxes = <ExportBox>[];
    if (_showBoundingBoxes) {
      for (final d in widget.detections) {
        final conf = readNumber(d, 'confidence');
        final bbox = d['bbox'] as Map<String, dynamic>?;
        if (bbox == null || conf < _minConfidence) continue;
        boxes.add(
          ExportBox(
            (bbox['x0'] as num).toDouble(),
            (bbox['y0'] as num).toDouble(),
            (bbox['x1'] as num).toDouble(),
            (bbox['y1'] as num).toDouble(),
            d['char']?.toString() ?? '?',
            conf,
          ),
        );
      }
    }

    final exportLines = <List<ExportCharacter>>[];
    for (final line in _lines) {
      final chars = <ExportCharacter>[];
      for (final i in _letterIndexesOf(line)) {
        final bytes = i < letterImages.length ? letterImages[i] : null;
        if (bytes == null) continue;
        final d = widget.detections[i];
        chars.add(
          ExportCharacter(
            bytes,
            d['char']?.toString() ?? '?',
            readNumber(d, 'confidence'),
          ),
        );
      }
      if (chars.isNotEmpty) exportLines.add(chars);
    }

    return ResultExport(
      filteredImage: image,
      filter: _filterLabel(filter),
      imageWidth: widget.imageWidth,
      imageHeight: widget.imageHeight,
      boxes: boxes,
      // Baybayin first, then the Latin letters that were read.
      translatedText:
          '${widget.baybayinText}\n'
          '${tr('Read as', 'Nabasa bilang')}: ${widget.latinText}',
      averageConfidence: _averageConfidence,
      characterCount: widget.detections.length,
      lines: exportLines,
      createdAt: DateTime.now(),
    );
  }

  /// Detection indexes of one line's letters, in reading order, keeping
  /// only letters at or above the confidence cut-off from Settings.
  List<int> _letterIndexesOf(List<Map<String, dynamic>> words) {
    final out = <int>[];
    for (final w in words) {
      final id = (w['word_id'] as num?)?.toInt() ?? -1;
      for (final i in _lettersByWord[id] ?? const <int>[]) {
        if (readNumber(widget.detections[i], 'confidence') >= _minConfidence) {
          out.add(i);
        }
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    // Content scrolls underneath the frosted app bar.
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const SizedBox.shrink(),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: DayawColors.text,
        elevation: 0,
        scrolledUnderElevation: 0,
        flexibleSpace: const GlassBar(child: SizedBox.expand()),
        leading: IconButton(
          tooltip: context.tr('Back', 'Bumalik'),
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          TextButton.icon(
            onPressed: _isExporting ? null : _openExportSheet,
            icon: _isExporting
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: DayawColors.amber,
                    ),
                  )
                : const Icon(Icons.ios_share_outlined),
            label: Text(
              _isExporting
                  ? context.tr('Exporting...', 'Ine-export...')
                  : context.tr('Export', 'I-export'),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: GlassBackground(
        child: SingleChildScrollView(
          physics: _lockPageScroll
              ? const NeverScrollableScrollPhysics()
              : null,
          padding: EdgeInsets.fromLTRB(
            20,
            topInset + 16,
            20,
            20 + MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildOriginalImageCard(),
              const SizedBox(height: 10),
              _buildFilterOptions(),
              const SizedBox(height: 24),
              DayawSectionTitle(
                context.tr('Results', 'Mga Resulta'),
                Icons.translate,
              ),
              const SizedBox(height: 12),
              _buildPredictedOutputCard(),
              if (_lines.isNotEmpty) ...[
                const SizedBox(height: 24),
                _subTitle(context.tr('Syllable Breakdown', 'Bawat Pantig')),
                const SizedBox(height: 12),
                for (var i = 0; i < _lines.length; i++)
                  _buildLineSection(i, _syllableCards(i, _lines[i])),
                const SizedBox(height: 8),
                _subTitle(context.tr('Letter Breakdown', 'Bawat Titik')),
                const SizedBox(height: 12),
                _buildLetterTable(),
              ],
              const SizedBox(height: 20),
              Text(
                context.tr(
                  '© 2026 DAYAW. All rights reserved.',
                  '© 2026 DAYAW. Nakalaan ang lahat ng karapatan.',
                ),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: DayawColors.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _subTitle(String text) => Text(
    text,
    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
  );

  // ---------------------------------------------------------------------
  // Photo with letter boxes + filters
  // ---------------------------------------------------------------------

  Widget _buildOriginalImageCard() {
    return GlassContainer(
      padding: const EdgeInsets.all(6),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 320),
        // Counting fingers on the image lets the page scroll be locked the
        // moment a second finger lands, before the scroll view can claim
        // the gesture and swallow the pinch.
        child: Listener(
          onPointerDown: (_) => _updateImagePointers(1),
          onPointerUp: (_) => _updateImagePointers(-1),
          onPointerCancel: (_) => _updateImagePointers(-1),
          child: GestureDetector(
            onDoubleTap: _resetZoom,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(14),
              child: InteractiveViewer(
                transformationController: _zoomController,
                minScale: 1,
                maxScale: 8,
                child: _buildImageWithBoxes(),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildImageWithBoxes() {
    // Until the filtered version is ready, the raw image stays visible.
    final displayBytes =
        _filteredSourceImages[_selectedFilter] ?? widget.sourceImage;
    final isLoading = _pendingFilters.contains(_selectedFilter);

    Widget sourceImage(BoxFit fit) => Stack(
      fit: StackFit.passthrough,
      children: [
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Image.memory(
            displayBytes,
            key: ValueKey(identityHashCode(displayBytes)),
            fit: fit,
            cacheWidth: 1600,
            cacheHeight: 1600,
            gaplessPlayback: true,
          ),
        ),
        if (isLoading)
          Positioned.fill(
            child: Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: DayawColors.amber,
                ),
              ),
            ),
          ),
      ],
    );
    if (widget.imageWidth <= 0 || widget.imageHeight <= 0) {
      return sourceImage(BoxFit.contain);
    }

    final boxes = <_BoundingBox>[];
    for (final d in widget.detections) {
      final conf = readNumber(d, 'confidence');
      if (conf < _minConfidence) continue;
      final bbox = d['bbox'] as Map<String, dynamic>?;
      if (bbox == null) continue;
      boxes.add(
        _BoundingBox(
          rect: Rect.fromLTRB(
            (bbox['x0'] as num).toDouble(),
            (bbox['y0'] as num).toDouble(),
            (bbox['x1'] as num).toDouble(),
            (bbox['y1'] as num).toDouble(),
          ),
          char: d['char']?.toString() ?? '?',
          color: _confidenceColor(conf),
        ),
      );
    }

    // Bboxes are in the backend's image space (imageWidth x imageHeight),
    // so the overlay is laid out at that aspect ratio and scaled to fit.
    return Center(
      heightFactor: 1,
      child: AspectRatio(
        aspectRatio: widget.imageWidth / widget.imageHeight,
        child: Stack(
          fit: StackFit.expand,
          children: [
            sourceImage(BoxFit.fill),
            if (_showBoundingBoxes)
              CustomPaint(
                painter: _BoundingBoxPainter(
                  boxes: boxes,
                  sourceWidth: widget.imageWidth,
                  sourceHeight: widget.imageHeight,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildBoundingBoxToggle() {
    return AnimatedContainer(
      duration: _uiAnimationDuration,
      curve: Curves.easeOutCubic,
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: _showBoundingBoxes ? _accentColor : DayawColors.surface,
        shape: BoxShape.circle,
        boxShadow: neuShadows(depth: 0.45),
      ),
      child: IconButton(
        tooltip: _showBoundingBoxes
            ? context.tr('Hide bounding boxes', 'Itago ang mga bounding box')
            : context.tr('Show bounding boxes', 'Ipakita ang mga bounding box'),
        padding: EdgeInsets.zero,
        style: ButtonStyle(
          overlayColor: WidgetStatePropertyAll(
            _accentColor.withValues(alpha: 0.3),
          ),
        ),
        icon: Icon(
          Icons.crop_free,
          size: 20,
          color: _showBoundingBoxes ? DayawColors.onSun : DayawColors.text,
        ),
        onPressed: () =>
            setState(() => _showBoundingBoxes = !_showBoundingBoxes),
      ),
    );
  }

  Widget _buildFilterOptions() {
    return Row(
      children: [
        Expanded(
          child: Container(
            padding: const EdgeInsets.all(3),
            decoration: neuSunken(
              borderRadius: const BorderRadius.all(Radius.circular(12)),
            ),
            child: LiquidGlassSelector(
              count: _filters.length,
              selectedIndex: _filters.indexOf(_selectedFilter),
              onChanged: (i) => _selectFilter(_filters[i]),
              itemBuilder: (context, i, selectedness) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  _filterLabel(_filters[i]),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Color.lerp(
                      DayawColors.textMuted,
                      DayawColors.onSun,
                      selectedness,
                    ),
                    fontWeight: FontWeight.w600,
                    fontSize: 11,
                  ),
                ),
              ),
            ),
          ),
        ),
        if (widget.imageWidth > 0 && widget.imageHeight > 0) ...[
          const SizedBox(width: 12),
          _buildBoundingBoxToggle(),
        ],
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Result card
  // ---------------------------------------------------------------------

  Widget _buildPredictedOutputCard() {
    final baybayin = widget.baybayinText;
    final latin = widget.latinText;
    final confidence = _averageConfidence;
    final words = [for (final l in _lines) ...l].length;

    return TweenAnimationBuilder<double>(
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
                if (confidence > 0) _resultConfidenceRing(confidence),
              ],
            ),
            const SizedBox(height: 12),
            SelectableText(
              baybayin.isEmpty ? '—' : baybayin,
              style: TextStyle(
                fontFamily: 'BaybayinCustom',
                fontSize: 32,
                color: DayawColors.text,
                height: 1.5,
                letterSpacing: 3.0,
              ),
            ),
            const SizedBox(height: 6),
            SelectableText(
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
                _resultStatChip(
                  Icons.text_fields,
                  context.tr(
                    '${widget.detections.length} letters',
                    '${widget.detections.length} titik',
                  ),
                ),
                _resultStatChip(
                  Icons.short_text,
                  context.tr(
                    '$words ${words == 1 ? 'word' : 'words'}',
                    '$words salita',
                  ),
                ),
                if (_lines.isNotEmpty)
                  _resultStatChip(
                    Icons.format_list_numbered,
                    context.tr(
                      '${_lines.length} '
                          '${_lines.length == 1 ? 'line' : 'lines'}',
                      '${_lines.length} linya',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: baybayin.isEmpty ? null : () => _copy(baybayin),
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
                onPressed: latin.isEmpty ? null : () => _copy(latin),
                style: OutlinedButton.styleFrom(
                  foregroundColor: DayawColors.text,
                  side: BorderSide(color: DayawColors.line, width: 1.2),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.copy_all_rounded, size: 18),
                label: Text(
                  context.tr('Copy Latin', 'Kopyahin ang Latin'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Circular gauge that fills up to the average confidence.
  Widget _resultConfidenceRing(double confidence) {
    final color = confidence >= 90
        ? DayawColors.leaf
        : confidence >= 75
        ? DayawColors.amber
        : DayawColors.brick;
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

  Widget _resultStatChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: neuSunken(borderRadius: BorderRadius.circular(20)),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: DayawColors.amber),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: DayawColors.text,
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Breakdowns
  // ---------------------------------------------------------------------

  /// One glass card per text line: the line number, then a sideways row.
  /// Tapping a syllable opens the Baybayin reference chart under the line.
  Widget _buildLineSection(int lineIndex, List<Widget> cards) {
    final chartOpen = _chartOpenFor?.line == lineIndex;
    return GlassContainer(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _buildVerticalLineLabel(lineIndex + 1),
              const SizedBox(width: 12),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(children: cards),
                ),
              ),
            ],
          ),
          AnimatedSize(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: chartOpen
                ? Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: _buildChartPanel(),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _buildVerticalLineLabel(int lineNumber) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$lineNumber',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            height: 1,
            color: DayawColors.amber,
          ),
        ),
        Text(
          context.tr('Line', 'Linya'),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: DayawColors.textMuted,
          ),
        ),
      ],
    );
  }

  /// Syllable cards for one line (Baybayin over Latin), with a small gap
  /// between words.
  List<Widget> _syllableCards(int lineIndex, List<Map<String, dynamic>> words) {
    final cards = <Widget>[];
    var index = 0;
    for (var w = 0; w < words.length; w++) {
      if (w > 0) cards.add(const SizedBox(width: 14));
      for (final s in (words[w]['syllables'] as List? ?? const [])) {
        if (s is! Map) continue;
        cards.add(
          _buildSyllableCard(
            s['latin']?.toString() ?? '',
            s['baybayin']?.toString() ?? '',
            (line: lineIndex, index: index++),
          ),
        );
      }
    }
    return cards;
  }

  Widget _buildSyllableCard(
    String latin,
    String baybayin,
    ({int line, int index}) key,
  ) {
    final chartOpen = _chartOpenFor == key;
    return InkWell(
      onTap: () => _toggleChart(key),
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: _uiAnimationDuration,
        curve: Curves.easeOutCubic,
        margin: const EdgeInsets.only(right: 8),
        width: 64,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: chartOpen
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(14),
                color: _accentColor,
                boxShadow: neuShadows(depth: 0.4),
              )
            : neuRaised(
                borderRadius: BorderRadius.circular(14),
                depth: 0.4,
              ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 40,
              child: Center(
                child: Text(
                  baybayin,
                  style: TextStyle(
                    fontFamily: 'BaybayinCustom',
                    fontSize: 28,
                    color: chartOpen ? DayawColors.onSun : DayawColors.text,
                  ),
                ),
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              width: 24,
              height: 2,
              decoration: BoxDecoration(
                color: chartOpen
                    ? DayawColors.onSun.withValues(alpha: 0.5)
                    : DayawColors.amber.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            Text(
              latin,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: chartOpen ? DayawColors.onSun : DayawColors.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _toggleChart(({int line, int index}) key) {
    setState(() {
      _chartOpenFor = _chartOpenFor == key ? null : key;
      _chartZoomController.value = Matrix4.identity();
    });
  }

  /// Small zoomable Baybayin reference chart, shown under the line whose
  /// syllable was tapped, to check the Baybayin against the chart.
  Widget _buildChartPanel() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 180,
        // The chart is a light image: keep its paper light in dark mode.
        decoration: BoxDecoration(
          color: const Color(0xFFF4F0E8),
          border: Border.all(color: DayawColors.line),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Listener(
          onPointerDown: (_) => _updateImagePointers(1),
          onPointerUp: (_) => _updateImagePointers(-1),
          onPointerCancel: (_) => _updateImagePointers(-1),
          child: GestureDetector(
            onDoubleTap: () => _chartZoomController.value = Matrix4.identity(),
            child: InteractiveViewer(
              transformationController: _chartZoomController,
              minScale: 1,
              maxScale: 8,
              child: Center(
                child: Image.asset(
                  'assets/images/baybayin_chart.jpg',
                  fit: BoxFit.contain,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLetterTable() {
    if (!_letterImagesByFilter.containsKey(_selectedFilter)) {
      // Still building this filter's crops in the background.
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: DayawColors.amber,
            ),
          ),
        ),
      );
    }

    final sections = <Widget>[];
    for (var l = 0; l < _lines.length; l++) {
      final cards = <Widget>[];
      var lastWord = -2;
      for (final i in _letterIndexesOf(_lines[l])) {
        final word = (widget.detections[i]['word_id'] as num?)?.toInt() ?? -1;
        if (lastWord != -2 && word != lastWord) {
          cards.add(const SizedBox(width: 14)); // gap between words
        }
        lastWord = word;
        final image = i < _letterImages.length ? _letterImages[i] : null;
        if (image == null) continue;
        cards.add(_buildLetterCard(widget.detections[i], image));
      }
      if (cards.isNotEmpty) sections.add(_buildLetterLine(l + 1, cards));
    }

    if (sections.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            context.tr('No letters detected.', 'Walang nakitang titik.'),
            style: TextStyle(color: DayawColors.textMuted),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: sections,
    );
  }

  Widget _buildLetterLine(int lineNumber, List<Widget> cards) {
    return GlassContainer(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      borderRadius: const BorderRadius.all(Radius.circular(16)),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _buildVerticalLineLabel(lineNumber),
          const SizedBox(width: 12),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: cards),
            ),
          ),
        ],
      ),
    );
  }

  /// The letter's image (per filter) | the letter it was read as, with
  /// its confidence.
  Widget _buildLetterCard(Map<String, dynamic> d, Uint8List image) {
    final conf = readNumber(d, 'confidence');
    final isProcessed = _selectedFilter == _hogFilter;
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(6),
      decoration: neuSunken(borderRadius: BorderRadius.circular(12)),
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                image,
                height: 64,
                width: 64,
                fit: BoxFit.contain,
                filterQuality: isProcessed
                    ? FilterQuality.none
                    : FilterQuality.medium,
                gaplessPlayback: true,
              ),
            ),
            VerticalDivider(
              width: 16,
              thickness: 1,
              color: DayawColors.line,
            ),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  d['char']?.toString() ?? '?',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: _confidenceColor(conf),
                  ),
                ),
                Text(
                  '${conf.round()}%',
                  style: TextStyle(fontSize: 10, color: DayawColors.textMuted),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------------------
// Background work (top-level so it can run via compute)
// -------------------------------------------------------------------------

class _LetterImagesRequest {
  final List<Map<String, dynamic>> detections;
  final Uint8List sourceImage;
  final double imageWidth;
  final double imageHeight;
  final String filter;

  const _LetterImagesRequest({
    required this.detections,
    required this.sourceImage,
    required this.imageWidth,
    required this.imageHeight,
    required this.filter,
  });
}

/// One image per detection, in the same order: HOG = the 56x56 image the
/// model classified; Raw / Black and White = the letter cut out of the
/// photo (falling back to the 56x56 image if there is no box).
List<Uint8List?> _buildLetterImages(_LetterImagesRequest request) {
  const rawFilter = _LatinResultScreenState._rawFilter;
  const blackWhiteFilter = _LatinResultScreenState._blackWhiteFilter;
  const hogFilter = _LatinResultScreenState._hogFilter;
  final filter = request.filter;

  img.Image? decodedSource; // decoded lazily, only if a crop is needed
  final out = <Uint8List?>[];
  for (final d in request.detections) {
    final processedImage = _decodeProcessedImage(d['processed_image']);
    Uint8List? rawImage;
    if (filter == rawFilter || filter == blackWhiteFilter) {
      decodedSource ??= img.decodeImage(request.sourceImage);
      if (decodedSource != null) {
        rawImage = _cropRawGlyph(
          decodedSource,
          d['bbox'],
          request.imageWidth,
          request.imageHeight,
        );
      }
    }
    final baseImage = filter == hogFilter
        ? processedImage ?? rawImage
        : rawImage ?? processedImage;
    out.add(
      filter == blackWhiteFilter && baseImage != null
          ? _blackAndWhitePng(baseImage)
          : baseImage,
    );
  }
  return out;
}

Uint8List? _decodeProcessedImage(dynamic value) {
  if (value is! String || value.isEmpty) return null;
  try {
    return base64Decode(value);
  } catch (_) {
    return null;
  }
}

/// Crops a letter out of the photo by its bbox. [imageWidth]/[imageHeight]
/// are the backend's coordinate space, which may differ from the decoded
/// photo's size, so crops are scaled by it.
Uint8List? _cropRawGlyph(
  img.Image decoded,
  dynamic bboxValue,
  double imageWidth,
  double imageHeight,
) {
  if (bboxValue is! Map) return null;
  final bbox = Map<String, dynamic>.from(bboxValue);

  final double scaleX = imageWidth > 0 ? decoded.width / imageWidth : 1.0;
  final double scaleY = imageHeight > 0 ? decoded.height / imageHeight : 1.0;

  final x0 = ((bbox['x0'] as num).toDouble() * scaleX).round().clamp(
    0,
    decoded.width - 1,
  );
  final y0 = ((bbox['y0'] as num).toDouble() * scaleY).round().clamp(
    0,
    decoded.height - 1,
  );
  final x1 = ((bbox['x1'] as num).toDouble() * scaleX).round().clamp(
    x0 + 1,
    decoded.width,
  );
  final y1 = ((bbox['y1'] as num).toDouble() * scaleY).round().clamp(
    y0 + 1,
    decoded.height,
  );

  final crop = img.copyCrop(
    decoded,
    x: x0,
    y: y0,
    width: x1 - x0,
    height: y1 - y0,
  );
  return Uint8List.fromList(img.encodePng(crop));
}

/// Largest side the full source image is shrunk to before filtering, so
/// big camera photos stay fast to process.
const int _maxFilterDimension = 1000;

img.Image _downscaleForFilter(img.Image image) {
  if (image.width <= _maxFilterDimension &&
      image.height <= _maxFilterDimension) {
    return image;
  }
  return image.width >= image.height
      ? img.copyResize(image, width: _maxFilterDimension)
      : img.copyResize(image, height: _maxFilterDimension);
}

/// Grayscale + threshold + invert: ink becomes white on black.
Uint8List _blackAndWhitePng(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  return Uint8List.fromList(
    img.encodePng(
      img.invert(
        img.luminanceThreshold(
          img.grayscale(_downscaleForFilter(decoded)),
          threshold: 0.65,
        ),
      ),
    ),
  );
}

/// Histogram of Oriented Gradients visualization of the full source image:
/// each 8x8 cell gets one line per orientation bin, along the edge
/// direction, with brightness proportional to that bin's strength.
Uint8List _hogVisualizationPng(Uint8List bytes) {
  const cellSize = 8;
  const bins = 9;
  const binWidth = math.pi / bins;

  final decoded = img.decodeImage(bytes);
  if (decoded == null) return bytes;
  final gray = img.grayscale(_downscaleForFilter(decoded));
  final w = gray.width;
  final h = gray.height;

  final luminance = Float32List(w * h);
  var i = 0;
  for (final pixel in gray) {
    luminance[i++] = pixel.r.toDouble();
  }

  final cellsX = w ~/ cellSize;
  final cellsY = h ~/ cellSize;
  final histogram = Float32List(cellsX * cellsY * bins);
  for (var y = 1; y < h - 1; y++) {
    final cy = y ~/ cellSize;
    if (cy >= cellsY) break;
    for (var x = 1; x < w - 1; x++) {
      final cx = x ~/ cellSize;
      if (cx >= cellsX) break;
      final gx = luminance[y * w + x + 1] - luminance[y * w + x - 1];
      final gy = luminance[(y + 1) * w + x] - luminance[(y - 1) * w + x];
      final magnitude = math.sqrt(gx * gx + gy * gy);
      if (magnitude == 0) continue;
      var angle = math.atan2(gy, gx);
      if (angle < 0) angle += math.pi;
      final bin = (angle / binWidth).floor() % bins;
      histogram[(cy * cellsX + cx) * bins + bin] += magnitude;
    }
  }

  final output = img.Image(width: w, height: h);
  var maxValue = 0.0;
  for (final value in histogram) {
    if (value > maxValue) maxValue = value;
  }
  if (maxValue == 0) return Uint8List.fromList(img.encodePng(output));

  const radius = cellSize / 2 - 0.5;
  for (var cy = 0; cy < cellsY; cy++) {
    for (var cx = 0; cx < cellsX; cx++) {
      final base = (cy * cellsX + cx) * bins;
      final centerX = cx * cellSize + cellSize / 2;
      final centerY = cy * cellSize + cellSize / 2;
      // Weakest bins first so the dominant edge direction ends on top.
      final order = List<int>.generate(bins, (b) => b)
        ..sort((a, b) => histogram[base + a].compareTo(histogram[base + b]));
      for (final b in order) {
        final strength = histogram[base + b] / maxValue;
        if (strength < 0.02) continue;
        final shade = (math.sqrt(strength) * 255).round().clamp(0, 255);
        final edgeAngle = (b + 0.5) * binWidth + math.pi / 2;
        final dx = math.cos(edgeAngle) * radius;
        final dy = math.sin(edgeAngle) * radius;
        img.drawLine(
          output,
          x1: (centerX - dx).round(),
          y1: (centerY - dy).round(),
          x2: (centerX + dx).round(),
          y2: (centerY + dy).round(),
          color: img.ColorRgb8(shade, shade, shade),
        );
      }
    }
  }
  return Uint8List.fromList(img.encodePng(output));
}

// -------------------------------------------------------------------------
// Letter boxes on the photo
// -------------------------------------------------------------------------

class _BoundingBox {
  final Rect rect;
  final String char;
  final Color color;

  _BoundingBox({required this.rect, required this.char, required this.color});
}

class _BoundingBoxPainter extends CustomPainter {
  final List<_BoundingBox> boxes;
  final double sourceWidth;
  final double sourceHeight;

  _BoundingBoxPainter({
    required this.boxes,
    required this.sourceWidth,
    required this.sourceHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final scaleX = size.width / sourceWidth;
    final scaleY = size.height / sourceHeight;

    for (final box in boxes) {
      final rect = Rect.fromLTRB(
        box.rect.left * scaleX,
        box.rect.top * scaleY,
        box.rect.right * scaleX,
        box.rect.bottom * scaleY,
      );
      canvas.drawRect(
        rect,
        Paint()
          ..color = box.color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );

      final label = TextPainter(
        text: TextSpan(
          text: box.char,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      // Label sits just above the box, or inside it if there's no room.
      final labelTop = rect.top - label.height - 2 >= 0
          ? rect.top - label.height - 2
          : rect.top;
      final labelRect = Rect.fromLTWH(
        rect.left,
        labelTop,
        label.width + 6,
        label.height + 2,
      );
      canvas.drawRect(labelRect, Paint()..color = box.color);
      label.paint(canvas, Offset(labelRect.left + 3, labelRect.top + 1));
    }
  }

  @override
  bool shouldRepaint(_BoundingBoxPainter oldDelegate) =>
      oldDelegate.boxes != boxes ||
      oldDelegate.sourceWidth != sourceWidth ||
      oldDelegate.sourceHeight != sourceHeight;
}