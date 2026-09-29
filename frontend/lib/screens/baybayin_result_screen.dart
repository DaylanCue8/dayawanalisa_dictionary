import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;

import '../services/app_language.dart';
import '../services/app_settings.dart';
import '../services/recognition_outcome.dart';
import '../services/result_exporter.dart';
import '../widgets/dayaw_style.dart';
import '../widgets/glass.dart';
import '../widgets/liquid_glass_selector.dart';

/// Full-screen results view for the Baybayin-to-Latin flow, reached after
/// a successful translate call. Shows the predicted output, a copy
/// button, and a side-by-side table of each character's PROCESSED image
/// (the exact 56x56 black-and-white glyph the model classified) against
/// its predicted Latin equivalent.
class BaybayinResultScreen extends StatefulWidget {
  final Uint8List sourceImage;
  final String translatedText;
  final List<Map<String, dynamic>> detections;

  // The backend's reported dimensions for the image it computed bbox
  // coordinates against. Only used by the raw-crop FALLBACK (for a
  // detection that arrives without a 'processed_image', e.g. from an
  // older backend). These are NOT guaranteed to equal the source image's
  // own decoded size - the pen pipeline can upscale before computing
  // bboxes - so crops are scaled by the ratio between the two.
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
  static const String _rawFilter = 'Raw';
  static const String _blackWhiteFilter = 'Black and White';
  static const String _hogFilter = 'HOG';

  // Starting filter / bounding boxes / confidence cut-off come from Settings.
  String _selectedFilter = _filters.contains(AppSettings.instance.resultFilter)
      ? AppSettings.instance.resultFilter
      : _hogFilter;
  bool _showBoundingBoxes = AppSettings.instance.showBoundingBoxesByDefault;
  final double _minConfidence = AppSettings.instance.minConfidence;
  List<_LineResult> _lineResults = const [];

  // Filtered versions of the full source image, keyed by filter. Built
  // in a background isolate the first time each filter is selected.
  final Map<String, Uint8List> _filteredSourceImages = {};
  final Set<String> _pendingFilters = {};

  // Pinch-to-zoom on the source image. While zoomed in, the page stops
  // scrolling so one-finger drags pan the image instead.
  final TransformationController _zoomController = TransformationController();
  bool _isZoomed = false;

  @override
  void initState() {
    super.initState();
    // The HOG view only base64-decodes the backend's crops, which is cheap
    // enough to do right away so the breakdown shows instantly. Raw /
    // Black and White decode the whole photo, so they load in the
    // background instead of stalling the page's slide-in.
    if (_selectedFilter == _hogFilter) {
      _lineResults = _buildLineResults(_lineResultsRequest(_selectedFilter));
      _lineResultsByFilter[_selectedFilter] = _lineResults;
    } else {
      _loadLineResults(_selectedFilter);
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

  void _onZoomChanged() {
    final zoomed = _zoomController.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _isZoomed) setState(() => _isZoomed = zoomed);
  }

  void _resetZoom() => _zoomController.value = Matrix4.identity();

  int _imagePointers = 0;

  void _updateImagePointers(int delta) {
    final wasPinching = _imagePointers >= 2;
    _imagePointers = math.max(0, _imagePointers + delta);
    if ((_imagePointers >= 2) != wasPinching) setState(() {});
  }

  bool get _lockPageScroll =>
      _isZoomed || _isChartZoomed || _imagePointers >= 2;

  // Which character's Latin letter has the reference chart open, if any.
  ({int line, int index})? _chartOpenFor;
  final TransformationController _chartZoomController =
      TransformationController();
  bool _isChartZoomed = false;

  void _onChartZoomChanged() {
    final zoomed = _chartZoomController.value.getMaxScaleOnAxis() > 1.01;
    if (zoomed != _isChartZoomed) setState(() => _isChartZoomed = zoomed);
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

  _LineResultsRequest _lineResultsRequest(String filter) => _LineResultsRequest(
    detections: widget.detections,
    sourceImage: widget.sourceImage,
    imageWidth: widget.imageWidth,
    imageHeight: widget.imageHeight,
    filter: filter,
    minConfidence: _minConfidence,
  );

  // Character crops per filter. Raw / Black and White have to decode the
  // whole photo, which would freeze the UI (and the filter pill's
  // animation), so those are built in a background isolate and cached.
  final Map<String, List<_LineResult>> _lineResultsByFilter = {};

  Future<void> _loadLineResults(String filter) async {
    final cached = _lineResultsByFilter[filter];
    if (cached != null) {
      setState(() => _lineResults = cached);
      return;
    }
    final lines = await compute(_buildLineResults, _lineResultsRequest(filter));
    if (!mounted) return;
    _lineResultsByFilter[filter] = lines;
    // Only show it if the user hasn't moved on to another filter meanwhile.
    if (filter == _selectedFilter) setState(() => _lineResults = lines);
  }

  Color _confidenceColor(double conf) {
    if (conf >= 90.0) return Colors.green;
    if (conf >= 80.0) return Colors.amber[800]!;
    if (conf >= 70.0) return Colors.red;
    return Colors.grey;
  }

  void _copyResult() {
    Clipboard.setData(ClipboardData(text: widget.translatedText));
    if (AppSettings.instance.hapticsEnabled) HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Copied to clipboard', 'Nakopya na')),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Export
  // ---------------------------------------------------------------------

  bool _isExporting = false;

  // (format, icon, English description, Filipino description)
  static const List<(ExportFormat, IconData, String, String)> _exportOptions = [
    (
      ExportFormat.jpg,
      Icons.image_outlined,
      'Image, small file size',
      'Larawan, maliit na file',
    ),
    (
      ExportFormat.png,
      Icons.photo_outlined,
      'Image, sharpest quality',
      'Larawan, pinakamalinaw',
    ),
    (
      ExportFormat.pdf,
      Icons.picture_as_pdf_outlined,
      'Document for printing',
      'Dokumento para i-print',
    ),
    (ExportFormat.txt, Icons.notes_rounded, 'Plain text only', 'Teksto lamang'),
  ];

  /// On-screen name of a filter (the filter keys themselves stay English).
  static String _filterLabel(String filter) => switch (filter) {
    _rawFilter => tr('Raw', 'Orihinal'),
    _blackWhiteFilter => tr('Black and White', 'Itim at Puti'),
    _ => filter,
  };

  Future<void> _openExportSheet() async {
    if (AppSettings.instance.hapticsEnabled) HapticFeedback.selectionClick();
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
                        'and the character breakdown.',
                    'Kasama ang larawan sa kasalukuyang filter, ang resulta '
                        'at ang bawat karakter.',
                  ),
                  style: const TextStyle(fontSize: 12.5, color: Colors.black54),
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
                        color: DayawColors.deepBrown,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Icon(icon, color: DayawColors.gold, size: 20),
                    ),
                    title: Text(
                      format.label,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: DayawColors.deepBrown,
                      ),
                    ),
                    subtitle: Text(context.tr(descEn, descFil)),
                    trailing: Icon(
                      Icons.chevron_right,
                      color: DayawColors.deepBrown.withValues(alpha: 0.4),
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
      await ResultExporter.share(await _collectExport(), format);
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
  /// boxes, if shown), the result and that filter's breakdown. Anything
  /// the filter hasn't finished building yet is built here first.
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

    final List<_LineResult> lines =
        _lineResultsByFilter[filter] ??
        await compute(_buildLineResults, _lineResultsRequest(filter));

    final boxes = <ExportBox>[];
    final confidences = <double>[];
    for (final d in widget.detections) {
      final conf = d['confidence'] is num ? readNumber(d, 'confidence') : null;
      if (conf != null) confidences.add(conf);
      final bbox = d['bbox'] as Map<String, dynamic>?;
      if (!_showBoundingBoxes || bbox == null) continue;
      if ((conf ?? 0) < _minConfidence) continue;
      boxes.add(
        ExportBox(
          (bbox['x0'] as num).toDouble(),
          (bbox['y0'] as num).toDouble(),
          (bbox['x1'] as num).toDouble(),
          (bbox['y1'] as num).toDouble(),
          d['char']?.toString() ?? '?',
          conf ?? 0,
        ),
      );
    }

    return ResultExport(
      filteredImage: image,
      filter: _filterLabel(filter),
      imageWidth: widget.imageWidth,
      imageHeight: widget.imageHeight,
      boxes: boxes,
      translatedText: widget.translatedText,
      averageConfidence: confidences.isEmpty
          ? 0
          : confidences.reduce((a, b) => a + b) / confidences.length,
      characterCount: widget.detections.length,
      lines: [
        for (final line in lines)
          [
            for (final c in line.results)
              ExportCharacter(c.image, c.char, c.confidence),
          ],
      ],
      createdAt: DateTime.now(),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Content scrolls underneath the frosted app bar, so the scroll view
    // starts its padding below the status bar + toolbar.
    final topInset = MediaQuery.paddingOf(context).top + kToolbarHeight;
    return Scaffold(
      backgroundColor: Colors.transparent,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const SizedBox.shrink(),
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        foregroundColor: Colors.brown,
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
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.brown,
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
              const SizedBox(height: 24),
              Text(
                context.tr('Character Breakdown', 'Bawat Karakter'),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
              const SizedBox(height: 12),
              _buildCharacterTable(),
              const SizedBox(height: 20),
              Text(
                context.tr(
                  '© 2026 DAYAW. All rights reserved.',
                  '© 2026 DAYAW. Nakalaan ang lahat ng karapatan.',
                ),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            ],
          ),
        ),
      ),
    );
  }

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

  Widget _buildBoundingBoxToggle() {
    return AnimatedContainer(
      duration: _uiAnimationDuration,
      curve: Curves.easeOutCubic,
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: _showBoundingBoxes ? _accentColor : Colors.black54,
        shape: BoxShape.circle,
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
          color: _showBoundingBoxes ? Colors.black87 : Colors.white,
        ),
        onPressed: () =>
            setState(() => _showBoundingBoxes = !_showBoundingBoxes),
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
        // Cross-fades between Raw / Black and White / HOG.
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
          const Positioned.fill(
            child: Center(
              child: SizedBox(
                width: 28,
                height: 28,
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: Colors.brown,
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

  // Same look as the Marker/Pen switch on the camera screen: a dark
  // rounded bar holding equal-width segments, the selected one yellow.
  static const Color _accentColor = Color(0xFFFFFF00);
  static const Duration _uiAnimationDuration = Duration(milliseconds: 220);

  Widget _buildFilterOptions() {
    return Row(
      children: [
        Expanded(
          // Dark frosted glass, so the yellow selection still pops.
          child: GlassContainer(
            padding: const EdgeInsets.all(3),
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            tint: const Color(0x8C000000),
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
                      Colors.white70,
                      Colors.black87,
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

  static const List<String> _filters = [
    _rawFilter,
    _blackWhiteFilter,
    _hogFilter,
  ];

  void _selectFilter(String filter) {
    if (filter == _selectedFilter) return;
    setState(() => _selectedFilter = filter);
    _loadLineResults(filter);
    _loadFilteredSourceImage(filter);
  }

  /// Same card as the Filipino to Baybayin tab's result: pops in with a
  /// label pill, confidence ring, quick stats and a full-width copy button.
  Widget _buildPredictedOutputCard() {
    final text = widget.translatedText;
    final confidences = widget.detections
        .map((d) => readNumber(d, 'confidence'))
        .whereType<double>()
        .toList();
    final confidence = confidences.isEmpty
        ? 0.0
        : confidences.reduce((a, b) => a + b) / confidences.length;
    final words = text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

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
        // Lightly honey-tinted glass for the result card.
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
                    gradient: const LinearGradient(
                      colors: [
                        DayawColors.gold,
                        DayawColors.yellow,
                        DayawColors.amber,
                      ],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(color: Color(0x33D9A441), blurRadius: 8),
                    ],
                  ),
                  child: Text(
                    context.tr('IN LATIN', 'SA LATIN'),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                      color: Colors.black87,
                    ),
                  ),
                ),
                const Spacer(),
                if (confidence > 0) _resultConfidenceRing(confidence),
              ],
            ),
            const SizedBox(height: 12),
            SelectableText(
              text.isEmpty ? '—' : text,
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: DayawColors.deepBrown,
                height: 1.2,
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
                    '${widget.detections.length} characters',
                    '${widget.detections.length} karakter',
                  ),
                ),
                _resultStatChip(
                  Icons.short_text,
                  context.tr(
                    '$words ${words == 1 ? 'word' : 'words'}',
                    '$words salita',
                  ),
                ),
                if (_lineResults.isNotEmpty)
                  _resultStatChip(
                    Icons.format_list_numbered,
                    context.tr(
                      '${_lineResults.length} '
                          '${_lineResults.length == 1 ? 'line' : 'lines'}',
                      '${_lineResults.length} linya',
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: text.isEmpty ? null : _copyResult,
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
        ? const Color(0xFF5E8B5A)
        : confidence >= 75
        ? const Color(0xFFC2873F)
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
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            DayawColors.yellow.withValues(alpha: 0.55),
            DayawColors.gold.withValues(alpha: 0.35),
          ],
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

  Widget _buildCharacterTable() {
    if (_lineResults.isEmpty &&
        !_lineResultsByFilter.containsKey(_selectedFilter)) {
      // Still building this filter's crops in the background.
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: Colors.brown,
            ),
          ),
        ),
      );
    }
    if (_lineResults.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: Text(
            context.tr(
              'No individual characters detected.',
              'Walang nakitang karakter.',
            ),
            style: const TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var index = 0; index < _lineResults.length; index++)
          _buildLineSection(index, _lineResults[index]),
      ],
    );
  }

  Widget _buildLineSection(int lineIndex, _LineResult line) {
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
                  child: Row(
                    children: [
                      for (var i = 0; i < line.results.length; i++)
                        _buildCharacterResult(line.results[i], (
                          line: lineIndex,
                          index: i,
                        )),
                    ],
                  ),
                ),
              ),
            ],
          ),
          // Chart slides open/closed instead of popping in.
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

  void _toggleChart(({int line, int index}) key) {
    setState(() {
      _chartOpenFor = _chartOpenFor == key ? null : key;
      _chartZoomController.value = Matrix4.identity();
    });
  }

  /// Small zoomable Baybayin reference chart, shown under the line whose
  /// Latin letter was tapped, to check a prediction against the chart.
  Widget _buildChartPanel() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        height: 180,
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Colors.brown.withValues(alpha: 0.25)),
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

  Widget _buildVerticalLineLabel(int lineNumber) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$lineNumber',
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            height: 1,
          ),
        ),
        Text(
          context.tr('Line', 'Linya'),
          style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _buildCharacterResult(
    _CharacterResult result,
    ({int line, int index}) key,
  ) {
    final chartOpen = _chartOpenFor == key;
    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.9)),
      ),
      child: IntrinsicHeight(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.memory(
                result.image,
                height: 64,
                width: 64,
                fit: BoxFit.contain,
                filterQuality: result.isProcessed
                    ? FilterQuality.none
                    : FilterQuality.medium,
                gaplessPlayback: true,
              ),
            ),
            VerticalDivider(
              width: 16,
              thickness: 1,
              color: Colors.brown.withValues(alpha: 0.25),
            ),
            // Tapping the Latin letter opens the reference chart; tapping
            // it again closes it.
            Center(
              child: InkWell(
                onTap: () => _toggleChart(key),
                borderRadius: BorderRadius.circular(8),
                child: AnimatedContainer(
                  duration: _uiAnimationDuration,
                  curve: Curves.easeOutCubic,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: chartOpen
                        ? _accentColor
                        : _accentColor.withValues(alpha: 0),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    result.char,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: _confidenceColor(result.confidence),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LineResultsRequest {
  final List<Map<String, dynamic>> detections;
  final Uint8List sourceImage;
  final double imageWidth;
  final double imageHeight;
  final String filter;
  // Passed in rather than read from AppSettings: a background isolate
  // has its own fresh copy of AppSettings with only the defaults.
  final double minConfidence;

  const _LineResultsRequest({
    required this.detections,
    required this.sourceImage,
    required this.imageWidth,
    required this.imageHeight,
    required this.filter,
    required this.minConfidence,
  });
}

/// Builds the Character Breakdown for one filter: picks each detection's
/// crop image, then groups the characters into lines (top to bottom) and
/// sorts each line left to right. Top-level so it can run via compute.
List<_LineResult> _buildLineResults(_LineResultsRequest request) {
  const rawFilter = _BaybayinResultScreenState._rawFilter;
  const blackWhiteFilter = _BaybayinResultScreenState._blackWhiteFilter;
  const hogFilter = _BaybayinResultScreenState._hogFilter;
  final filter = request.filter;

  final results = <_CharacterResult>[];
  img.Image? decodedSource; // decoded lazily, only if a fallback is needed

  for (final d in request.detections) {
    final conf = readNumber(d, 'confidence');
    if (conf < request.minConfidence) continue;

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
    final imageBytes = filter == blackWhiteFilter && baseImage != null
        ? _blackAndWhitePng(baseImage)
        : baseImage;
    if (imageBytes == null) continue;

    final bbox = d['bbox'] as Map<String, dynamic>?;
    if (bbox == null) continue;

    results.add(
      _CharacterResult(
        image: imageBytes,
        char: d['char']?.toString() ?? '?',
        confidence: conf,
        isProcessed: filter == hogFilter,
        centerX:
            ((bbox['x0'] as num).toDouble() + (bbox['x1'] as num).toDouble()) /
            2,
        centerY:
            ((bbox['y0'] as num).toDouble() + (bbox['y1'] as num).toDouble()) /
            2,
        height: (bbox['y1'] as num).toDouble() - (bbox['y0'] as num).toDouble(),
      ),
    );
  }

  results.sort((a, b) => a.centerY.compareTo(b.centerY));
  final lines = <_LineResult>[];
  for (final result in results) {
    final currentLine = lines.isEmpty ? null : lines.last;
    final lineTolerance = currentLine == null
        ? 0
        : (currentLine.maxHeight > result.height
                  ? currentLine.maxHeight
                  : result.height) *
              0.7;
    if (currentLine == null ||
        (result.centerY - currentLine.centerY).abs() > lineTolerance) {
      lines.add(
        _LineResult(
          results: [result],
          centerY: result.centerY,
          maxHeight: result.height,
        ),
      );
    } else {
      currentLine.results.add(result);
      currentLine.centerY =
          currentLine.results
              .map((item) => item.centerY)
              .reduce((a, b) => a + b) /
          currentLine.results.length;
      if (result.height > currentLine.maxHeight) {
        currentLine.maxHeight = result.height;
      }
    }
  }
  for (final line in lines) {
    line.results.sort((a, b) => a.centerX.compareTo(b.centerX));
  }
  return lines;
}

Uint8List? _decodeProcessedImage(dynamic value) {
  if (value is! String || value.isEmpty) return null;
  try {
    return base64Decode(value);
  } catch (_) {
    return null;
  }
}

/// Fallback only: crops the glyph out of the raw photo by its bbox.
/// [imageWidth]/[imageHeight] are the backend's coordinate space, which
/// may differ from the decoded photo's size, so crops are scaled by it.
Uint8List? _cropRawGlyph(
  img.Image decoded,
  dynamic bboxValue,
  double imageWidth,
  double imageHeight,
) {
  final bbox = bboxValue as Map<String, dynamic>?;
  if (bbox == null) return null;

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

/// Grayscale + threshold + invert: ink becomes white on black. Used for
/// both the per-character crops and (via compute) the full source image.
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

/// Histogram of Oriented Gradients visualization of the full source image,
/// drawn the way skimage's hog(visualize=True) does: each 8x8 cell gets
/// one line per orientation bin, running along the edge direction, with
/// brightness proportional to that bin's gradient strength.
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
        // sqrt lifts faint strokes so they stay visible on a phone screen.
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

class _CharacterResult {
  final Uint8List image;
  final String char;
  final double confidence;
  final bool isProcessed;
  final double centerX;
  final double centerY;
  final double height;

  _CharacterResult({
    required this.image,
    required this.char,
    required this.confidence,
    this.isProcessed = false,
    required this.centerX,
    required this.centerY,
    required this.height,
  });
}

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

class _LineResult {
  final List<_CharacterResult> results;
  double centerY;
  double maxHeight;

  _LineResult({
    required this.results,
    required this.centerY,
    required this.maxHeight,
  });
}
