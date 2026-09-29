import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show applyBoxFit, FittedSizes;
import 'package:image/image.dart' as img;
import '../services/api_service.dart';
import '../services/offline_recognizer.dart';
import '../widgets/image_cropper_widget.dart';
import '../screens/camera_capture_screen.dart';
import '../screens/baybayin_result_screen.dart';
import '../widgets/glass.dart';

/// Handles the "Baybayin to Latin" mode: capture/upload a photo, crop it,
/// send it for translation, and show the result. Fully self-contained —
/// owns its own state, independent of the text-translation mode.
class BaybayinToTagalogView extends StatefulWidget {
  const BaybayinToTagalogView({super.key});

  @override
  State<BaybayinToTagalogView> createState() => _BaybayinToTagalogViewState();
}

class _BaybayinToTagalogViewState extends State<BaybayinToTagalogView>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();

  // true  = recognize on the phone (offline, Chaquopy - Android only)
  // false = send the photo to the Flask server like before
  static const bool _useOfflineRecognizer = true;

  /// One looping 0..1 clock that drives every ambient animation on this
  /// tab (glow border, breathing button, radar rings, scan line), so the
  /// whole screen moves in sync and only one ticker runs.
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  )..repeat();

  // "Did you know?" card: rotates to the next fact every few seconds.
  Timer? _factTimer;
  int _factIndex = 0;

  @override
  void initState() {
    super.initState();
    // Load the models in the background so the first scan isn't slow
    if (_useOfflineRecognizer) OfflineRecognizer.warmUp();
    _factTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (mounted) {
        setState(() => _factIndex = (_factIndex + 1) % _facts.length);
      }
    });
  }

  @override
  void dispose() {
    _factTimer?.cancel();
    _ambient.dispose();
    super.dispose();
  }

  String _translatedResult = "Result will appear here";
  bool _isLoading = false;
  Uint8List? _webImage;

  // Bounding-box overlay state, populated from the API's
  // individual_detections + image_width/image_height fields.
  List<Map<String, dynamic>> _detections = [];
  double _imageWidth = 0;
  double _imageHeight = 0;

  // The last successful result, kept so the person can open the result
  // screen again after going back (button, tap on the result bar, or
  // swipe right-to-left on the image).
  Map<String, dynamic>? _lastResultData;

  // Swipe-left tracking (finger position when it touched the image)
  Offset? _swipeStart;
  Offset? _tabSwipeStart;
  static const double _swipeMinDistance = 60; // logical pixels

  /// Bakes the EXIF orientation into the actual pixel data (rotating/
  /// flipping as needed) and strips the orientation tag, producing a
  /// single normalized image. This MUST happen before the image is
  /// either displayed or uploaded, so:
  ///   1. What the user sees on screen,
  ///   2. What bytes get sent to the backend, and
  ///   3. The (width, height) + bounding boxes the backend computes,
  /// are all guaranteed to agree on the same pixel grid. Without this,
  /// a backend that EXIF-corrects (as this one does, via
  /// ImageOps.exif_transpose) can compute boxes against a rotated
  /// image while Flutter's Image.memory displays the raw, un-rotated
  /// bytes - causing exactly the kind of misaligned boxes you'd see
  /// with any camera photo carrying an EXIF orientation tag.
  ///
  /// Kept even for the custom camera screen: some devices still embed
  /// EXIF orientation on captured JPEGs, so this stays as a safety net
  /// regardless of capture source.
  Uint8List _normalizeOrientation(Uint8List bytes) {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final oriented = img.bakeOrientation(decoded);
    // Quality bumped from 90 to 95 - this re-encode happens on every
    // capture regardless of source, so keep it as close to lossless
    // as practical for thin-stroke detail.
    return Uint8List.fromList(img.encodeJpg(oriented, quality: 95));
  }

  Future<void> _processCroppedImage(
    Uint8List imageBytes, {
    required String inputType,
  }) async {
    setState(() {
      _isLoading = true;
      _translatedResult = 'Processing Image...';
      _detections = [];
      _lastResultData = null;
    });

    final response = _useOfflineRecognizer
        ? await OfflineRecognizer.recognize(imageBytes, inputType: inputType)
        : await _apiService.uploadAndTranslateDetailed(
            null,
            'Baybayin to Tagalog',
            imageBytes: imageBytes,
            inputType: inputType,
          );

    if (!mounted) return;

    setState(() {
      _isLoading = false;
      if (response != null) {
        _translatedResult = response['translated_text'] ?? 'No result';

        final rawDetections = response['individual_detections'] as List? ?? [];
        _detections = rawDetections
            .whereType<Map>()
            .map((d) => Map<String, dynamic>.from(d))
            .where((d) => d['bbox'] != null)
            .toList();
        _imageWidth = (response['image_width'] as num?)?.toDouble() ?? 0;
        _imageHeight = (response['image_height'] as num?)?.toDouble() ?? 0;

        // Non-null only when the photo's letters came out too small
        // for diacritics to reliably survive segmentation (see
        // LOW_RESOLUTION_WARNING_THRESHOLD_PX in the backend) - a
        // resolution issue with THIS photo, not a translation error,
        // so it's shown alongside the result rather than replacing it.
        final lowResolutionWarning =
            response['low_resolution_warning'] as String?;
        if (lowResolutionWarning != null && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(lowResolutionWarning),
              duration: const Duration(seconds: 5),
              backgroundColor: Colors.orange[800],
            ),
          );
        }

        String status = response['status']?.toString().toLowerCase() ?? '';
        if (status == 'success' || status == 'low_confidence') {
          _lastResultData = response;
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) _showResults(imageBytes, response);
          });
        } else if (status == 'no_characters' || _translatedResult.isEmpty) {
          _translatedResult = 'No Baybayin letters found. Try a clearer crop.';
        }
      } else {
        _translatedResult = _useOfflineRecognizer
            ? 'Error: Could not process the image'
            : 'Error: Connection Failed';
      }
    });
  }

  /// Shared camera pipeline: normalize orientation, let the user crop, then
  /// run the offline recognizer.
  Future<void> _handleRawImage(
    Uint8List rawBytes, {
    required String inputType,
  }) async {
    if (!mounted) return;

    // Normalize orientation BEFORE cropping, so the crop UI itself
    // (and everything downstream of it) works against the same
    // pixel grid the backend will later compute boxes against.
    final bytes = _normalizeOrientation(rawBytes);

    final Uint8List? croppedBytes = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => ImageCropperScreen(imageData: bytes)),
    );

    if (croppedBytes == null) return;

    setState(() {
      _isLoading = true;
      _translatedResult = 'Processing Image...';
      _detections = [];
      // Orientation is already normalized above, and cropping doesn't
      // introduce any new orientation metadata, so these bytes, what
      // gets displayed, and what the backend analyzes all match.
      _webImage = croppedBytes;
    });

    await _processCroppedImage(croppedBytes, inputType: inputType);
  }

  /// Now uses the custom CameraCaptureScreen (camera package) instead
  /// of image_picker's OS camera, so we can force a high resolution
  /// preset and lock focus/exposure before capture - neither of which
  /// the OS camera app exposes to us.
  Future<void> _captureFromCamera() async {
    final CameraCaptureResult? captured = await Navigator.of(context)
        .push<CameraCaptureResult>(
          MaterialPageRoute(builder: (_) => const CameraCaptureScreen()),
        );
    if (captured == null) return;

    await _handleRawImage(captured.imageBytes, inputType: captured.inputType);
  }

  /// Opens the result screen again for the last photo (if there is one).
  void _openLastResult() {
    final image = _webImage;
    final data = _lastResultData;
    if (_isLoading || image == null || data == null) return;
    _showResults(image, data);
  }

  void _showResults(Uint8List sourceImage, Map<String, dynamic> data) {
    Navigator.of(context).push(
      // The app theme gives every MaterialPageRoute the iOS transition:
      // slides in from the right (matching the swipe gesture), with
      // parallax on the page underneath and swipe-back to close.
      MaterialPageRoute(
        builder: (_) => BaybayinResultScreen(
          sourceImage: sourceImage,
          translatedText: data['translated_text']?.toString() ?? '',
          detections: (data['individual_detections'] as List? ?? [])
              .whereType<Map>()
              .map((d) => Map<String, dynamic>.from(d))
              .toList(),
          // The backend's reported dimensions for THIS response - these
          // already exist in state (_imageWidth/_imageHeight, set right
          // above from the same response) but were never being passed
          // through to the result screen. Without them, the result
          // screen has no way to detect or correct for a mismatch
          // between the backend's coordinate space and its own local
          // decode of sourceImage, which is what caused crops to land
          // on the wrong sub-region (e.g. showing only half a letter).
          imageWidth: (data['image_width'] as num?)?.toDouble() ?? 0,
          imageHeight: (data['image_height'] as num?)?.toDouble() ?? 0,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // UI
  //
  // A layered, always-moving "scanner hub": animated glowing hero card,
  // breathing call-to-action, a rich result card, scan tips and rotating
  // Baybayin facts. Dense and lively on purpose, but every piece is
  // either an action, the result, or something that helps the next scan.
  // ---------------------------------------------------------------------

  static const Color _amber = Color(0xFFFFB300);
  static const Color _gold = Color(0xFFFFFF00);
  // Rich lemon yellow - the lead accent. Gradients run amber -> _yellow ->
  // _gold so they stay warm but read as clearly yellow.
  static const Color _yellow = Color(0xFFFFE000);
  static const Color _deepBrown = Color(0xFF4E342E);

  static const List<(IconData, Color, String)> _tips = [
    (Icons.edit, Color(0xFF263238), 'Black ink'),
    (Icons.description_outlined, Color(0xFF5C6BC0), 'Plain white paper'),
    (Icons.space_bar, Color(0xFF26A69A), 'Space out letters'),
    (Icons.more_horiz, Color(0xFFEF6C00), 'Clear kudlits'),
    (Icons.wb_sunny_outlined, Color(0xFFF9A825), 'No glare or shadow'),
    (Icons.crop_free, Color(0xFF8E24AA), 'Fill the frame'),
  ];

  static const List<(String, String)> _facts = [
    (
      'ᜊᜌ᜔ᜊᜌᜒᜈ᜔',
      '"Baybayin" comes from "baybay", the Tagalog word for "to spell".',
    ),
    (
      'ᜃ ᜃᜒ ᜃᜓ',
      'A kudlit above a letter turns its "a" into "e/i"; below, into "o/u".',
    ),
    ('ᜃ᜔', 'The cross-shaped kudlit, added in 1620, removes the vowel sound.'),
    ('ᜇ', 'D and R share one letter in Baybayin - context tells them apart.'),
    ('ᜀ ᜁ ᜂ', 'Baybayin has 17 basic letters: 3 vowels and 14 consonants.'),
  ];

  /// 0..1..0 once per ambient loop - for breathing / pulsing.
  double get _breath => 0.5 - 0.5 * math.cos(2 * math.pi * _ambient.value);

  double get _confidenceScore {
    final data = _lastResultData;
    if (data == null) return 0;
    final overall = data['confidence'];
    if (overall is num) return overall.toDouble();
    final values = _detections
        .map((d) => (d['confidence'] as num?)?.toDouble())
        .whereType<double>()
        .toList();
    if (values.isEmpty) return 0;
    return values.reduce((a, b) => a + b) / values.length;
  }

  Color _confidenceColor(double confidence) {
    if (confidence >= 90) return const Color(0xFF2E7D32);
    if (confidence >= 75) return const Color(0xFFEF6C00);
    return const Color(0xFFC62828);
  }

  @override
  Widget build(BuildContext context) {
    final hasResult = _lastResultData != null && !_isLoading;
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        _buildHeroHeader(),
        const SizedBox(height: 16),
        _buildScannerCard(),
        const SizedBox(height: 18),
        _buildScanButton(),
        if (hasResult || (_webImage != null && !_isLoading)) ...[
          const SizedBox(height: 24),
          _buildResultCard(),
        ],
        const SizedBox(height: 28),
        _sectionTitle('Tips for a perfect scan', Icons.auto_awesome),
        const SizedBox(height: 12),
        _buildTips(),
        const SizedBox(height: 28),
        _sectionTitle('Did you know?', Icons.lightbulb_outline),
        const SizedBox(height: 12),
        _buildFactCard(),
      ],
    );
  }

  Widget _sectionTitle(String text, IconData icon) {
    return Row(
      children: [
        // Yellow-to-amber gradient icon.
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [Color(0xFFFFC400), Color(0xFFFF8F00)],
          ).createShader(bounds),
          child: Icon(icon, size: 20, color: Colors.white),
        ),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: _deepBrown,
            ),
          ),
        ),
      ],
    );
  }

  /// Title with a gradient headline and a strip of Baybayin that gently
  /// shimmers, so the screen feels alive before anything is scanned.
  Widget _buildHeroHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            // Ends in a deep golden yellow (not pure yellow, which would
            // vanish on the cream background).
            colors: [_deepBrown, Color(0xFFE08E00), Color(0xFFF5B800)],
          ).createShader(bounds),
          child: const Text(
            'Read the ancient script',
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              height: 1.1,
            ),
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Snap handwritten Baybayin and get Filipino in seconds.',
          style: TextStyle(fontSize: 13, color: Colors.black54),
        ),
        const SizedBox(height: 8),
        AnimatedBuilder(
          animation: _ambient,
          builder: (context, _) => ShaderMask(
            shaderCallback: (bounds) => LinearGradient(
              begin: Alignment(-1 + 3 * _ambient.value - 1, 0),
              end: Alignment(1 + 3 * _ambient.value - 1, 0),
              colors: const [Color(0x66795548), _yellow, Color(0x66795548)],
            ).createShader(bounds),
            child: const Text(
              'ᜊᜌ᜔ᜊᜌᜒᜈ᜔ · ᜇᜌᜏ᜔ · ᜆᜄᜎᜓᜄ᜔',
              style: TextStyle(
                fontFamily: 'BaybayinCustom',
                fontSize: 20,
                color: Colors.white,
                letterSpacing: 2,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The photo (or the empty scanner), framed by a slowly rotating
  /// gradient glow.
  Widget _buildScannerCard() {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ambient,
        builder: (context, child) {
          final glow = _isLoading ? 1.0 : 0.35 + 0.35 * _breath;
          return Container(
            height: 300,
            padding: const EdgeInsets.all(2.5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              gradient: SweepGradient(
                transform: GradientRotation(2 * math.pi * _ambient.value),
                colors: const [
                  // Starts and ends on the same yellow so the rotating
                  // seam is invisible.
                  _yellow,
                  _amber,
                  _gold,
                  _yellow,
                  Color(0xFFFF8F00),
                  _gold,
                  _yellow,
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: _yellow.withValues(alpha: 0.55 * glow),
                  blurRadius: 22 + 18 * glow,
                  spreadRadius: 2 + 2 * glow,
                ),
              ],
            ),
            child: child,
          );
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(23.5),
          child: ColoredBox(
            color: const Color(0xFFFFFBF5),
            child: Stack(
              children: [
                // Swipe right-to-left on the image to open the last result
                // again. A Listener (raw touches) is used instead of a
                // GestureDetector: it can't be "stolen" by a parent that
                // also handles horizontal drags, and it works on distance,
                // so a slow swipe counts too.
                Positioned.fill(
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: (e) => _swipeStart = e.position,
                    onPointerUp: (e) {
                      final start = _swipeStart;
                      _swipeStart = null;
                      if (start == null) return;
                      final dx = e.position.dx - start.dx;
                      final dy = e.position.dy - start.dy;
                      if (dx < -_swipeMinDistance &&
                          dx.abs() > dy.abs() * 1.5) {
                        _openLastResult();
                      }
                    },
                    onPointerCancel: (_) => _swipeStart = null,
                    child: _webImage == null
                        ? _buildEmptyScanner()
                        : _buildImageDisplay(),
                  ),
                ),
                // Side tab on the right edge: tap it or swipe it left to
                // open the last result again (only after a successful scan).
                if (_lastResultData != null && !_isLoading)
                  Positioned(
                    right: 0,
                    top: 0,
                    bottom: 0,
                    child: Center(child: _buildResultSideTab()),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Empty state: radar rings pulse out from a scanner icon while a scan
  /// line sweeps the card. Tap anywhere to open the camera.
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
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [_gold, _yellow, _amber],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x88FFC400),
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
                  'Tap to start scanning',
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
            color: Color.lerp(
              _yellow,
              _amber,
              t,
            )!.withValues(alpha: (1 - t) * 0.9),
            width: 3 - t,
          ),
        ),
      ),
    );
  }

  /// Horizontal glowing line sweeping top to bottom.
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
            gradient: LinearGradient(
              colors: [
                _amber.withValues(alpha: 0),
                _yellow.withValues(alpha: faint ? 0.75 : 1),
                _gold,
                _yellow.withValues(alpha: faint ? 0.75 : 1),
                _amber.withValues(alpha: 0),
              ],
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
    final hasBoxes =
        !_isLoading &&
        _webImage != null &&
        _detections.isNotEmpty &&
        _imageWidth > 0 &&
        _imageHeight > 0;

    return Stack(
      children: [
        Center(
          child: Image.memory(
            _webImage!,
            fit: BoxFit.contain,
            cacheWidth: 1600,
            cacheHeight: 1600,
          ),
        ),
        // Drawn on top of the image, sized to the same box, so the
        // painter can replicate BoxFit.contain's letterboxing math and
        // land each box in the right place regardless of crop aspect ratio.
        if (hasBoxes)
          Positioned.fill(
            child: CustomPaint(
              painter: _DetectionBoxPainter(
                imageSize: Size(_imageWidth, _imageHeight),
                detections: _detections,
              ),
            ),
          ),
        // While reading: the photo dims, a bright scan line sweeps it and
        // a pill says what's happening.
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
                                'Reading strokes${'.' * (1 + (_ambient.value * 3).floor() % 3)}',
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

  /// Big breathing gradient button - the one obvious next step.
  Widget _buildScanButton() {
    final label = _webImage == null ? 'Scan with Camera' : 'Scan Again';
    return AnimatedBuilder(
      animation: _ambient,
      builder: (context, child) => Transform.scale(
        scale: _isLoading ? 1 : 1 + 0.02 * _breath,
        child: Container(
          height: 58,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(29),
            // Yellow gradient whose bright band slowly drifts back and
            // forth, like light moving across it.
            gradient: LinearGradient(
              begin: Alignment(-1.6 + 1.2 * _breath, 0),
              end: Alignment(1.6 + 1.2 * _breath, 0),
              colors: _isLoading
                  ? [Colors.grey.shade400, Colors.grey.shade500]
                  : const [_amber, _yellow, _gold, _yellow, _amber],
            ),
            border: Border.all(
              color: Colors.white.withValues(alpha: _isLoading ? 0 : 0.7),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(
                  0xFFFFC400,
                ).withValues(alpha: _isLoading ? 0 : 0.45 + 0.3 * _breath),
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

  /// The last scan's translation, with a confidence ring, quick stats and
  /// a button into the full breakdown. Also shows "nothing found" / error
  /// messages when a scan didn't produce a result.
  Widget _buildResultCard() {
    final data = _lastResultData;
    if (data == null) {
      return GlassContainer(
        padding: const EdgeInsets.all(18),
        child: Row(
          children: [
            const Icon(Icons.info_outline, color: Color(0xFFEF6C00)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _translatedResult,
                style: const TextStyle(fontSize: 14, color: Colors.black87),
              ),
            ),
          ],
        ),
      );
    }

    final confidence = _confidenceScore;
    final color = _confidenceColor(confidence);
    final characters = _detections.length;
    final words = _translatedResult
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .length;

    return TweenAnimationBuilder<double>(
      // Pops in with a little rise + fade each time a new result lands.
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
        // Yellow-tinted glass so the result card glows with the accent.
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
                      colors: [_gold, _yellow, _amber],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(color: Color(0x66FFC400), blurRadius: 10),
                    ],
                  ),
                  child: const Text(
                    'LAST CAPTURED',
                    style: TextStyle(
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
            Text(
              _translatedResult,
              style: const TextStyle(
                fontSize: 26,
                fontWeight: FontWeight.w900,
                color: _deepBrown,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _statChip(Icons.text_fields, '$characters characters'),
                _statChip(
                  Icons.short_text,
                  '$words ${words == 1 ? 'word' : 'words'}',
                ),
                _statChip(Icons.offline_bolt_outlined, 'On-device'),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _openLastResult,
                style: FilledButton.styleFrom(
                  backgroundColor: _deepBrown,
                  foregroundColor: _yellow,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.grid_view_rounded, size: 18),
                label: const Text(
                  'View character breakdown',
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Circular gauge that fills up to the confidence when it appears.
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
        gradient: LinearGradient(
          colors: [
            _yellow.withValues(alpha: 0.55),
            _gold.withValues(alpha: 0.35),
          ],
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

  /// Sideways-scrolling row of colorful tip cards.
  Widget _buildTips() {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: _tips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final (icon, color, label) = _tips[i];
          return Container(
            width: 112,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                // Each tip keeps its own color at the top, flowing into a
                // shared yellow wash, so the row reads as one yellow family.
                colors: [
                  color.withValues(alpha: 0.16),
                  _yellow.withValues(alpha: 0.28),
                  _gold.withValues(alpha: 0.45),
                ],
              ),
              border: Border.all(color: _yellow.withValues(alpha: 0.9)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33FFC400),
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
                    color: color,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: Colors.white, size: 18),
                ),
                const Spacer(),
                Text(
                  label,
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

  /// Rotating fact with a big Baybayin sample; slides/fades between facts
  /// and shows which one you're on.
  Widget _buildFactCard() {
    final (sample, fact) = _facts[_factIndex];
    return GestureDetector(
      // Tap to skip to the next fact.
      onTap: () =>
          setState(() => _factIndex = (_factIndex + 1) % _facts.length),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            // Dark brown warming into a golden corner.
            colors: [_deepBrown, Color(0xFF8D4A2B), Color(0xFFC77800)],
            stops: [0, 0.6, 1],
          ),
          border: Border.all(color: _yellow.withValues(alpha: 0.7), width: 1.5),
          boxShadow: const [
            BoxShadow(
              color: Color(0x55FFC400),
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
                  'Tap for next',
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

  /// Small tab stuck to the right edge of the photo panel (like a drawer
  /// handle). Tap it, or swipe it to the left, to open the result screen.
  Widget _buildResultSideTab() {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => _tabSwipeStart = e.position,
      onPointerUp: (e) {
        final start = _tabSwipeStart;
        _tabSwipeStart = null;
        if (start == null) return;
        final dx = e.position.dx - start.dx;
        final dy = e.position.dy - start.dy;
        final isTap = dx.abs() < 10 && dy.abs() < 10;
        final isSwipeLeft = dx < -30 && dx.abs() > dy.abs();
        if (isTap || isSwipeLeft) _openLastResult();
      },
      onPointerCancel: (_) => _tabSwipeStart = null,
      child: Container(
        width: 30,
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: const BoxDecoration(
          color: Colors.brown,
          borderRadius: BorderRadius.only(
            topLeft: Radius.circular(14),
            bottomLeft: Radius.circular(14),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black26,
              blurRadius: 6,
              offset: Offset(-2, 2),
            ),
          ],
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.chevron_left, color: Colors.white, size: 22),
            SizedBox(height: 6),
            RotatedBox(
              quarterTurns: 3,
              child: Text(
                'RESULT',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
            ),
            SizedBox(height: 6),
            Icon(Icons.chevron_left, color: Colors.white, size: 22),
          ],
        ),
      ),
    );
  }
}

/// Paints each detection's bbox on top of an Image.memory(fit: BoxFit.contain).
/// Uses applyBoxFit to find exactly where Flutter placed/letterboxed the
/// image inside the available space, then scales original-pixel bbox
/// coordinates into that same rect.
class _DetectionBoxPainter extends CustomPainter {
  final Size imageSize; // native pixel size of the uploaded image
  final List<Map<String, dynamic>> detections;
  final bool showLabels;

  _DetectionBoxPainter({
    required this.imageSize,
    required this.detections,
    this.showLabels = true,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (imageSize.width <= 0 || imageSize.height <= 0) return;

    final FittedSizes fitted = applyBoxFit(BoxFit.contain, imageSize, size);
    final destSize = fitted.destination;
    final offsetX = (size.width - destSize.width) / 2;
    final offsetY = (size.height - destSize.height) / 2;
    final scaleX = destSize.width / imageSize.width;
    final scaleY = destSize.height / imageSize.height;

    final boxPaint = Paint()
      ..color =
          const Color(0xFF00E676) // green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    for (final d in detections) {
      final bbox = d['bbox'] as Map<String, dynamic>?;
      if (bbox == null) continue;
      final x0 = (bbox['x0'] as num).toDouble();
      final y0 = (bbox['y0'] as num).toDouble();
      final x1 = (bbox['x1'] as num).toDouble();
      final y1 = (bbox['y1'] as num).toDouble();

      final rect = Rect.fromLTRB(
        offsetX + x0 * scaleX,
        offsetY + y0 * scaleY,
        offsetX + x1 * scaleX,
        offsetY + y1 * scaleY,
      );
      canvas.drawRect(rect, boxPaint);

      if (showLabels) {
        // Label shows the character only now - confidence percentage
        // removed per request (was previously "$char ${confidence}%").
        final char = d['char']?.toString() ?? '';
        final textPainter = TextPainter(
          text: TextSpan(
            text: char,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 11,
              backgroundColor: Color(0xCC000000),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        textPainter.paint(
          canvas,
          Offset(
            rect.left,
            (rect.top - textPainter.height).clamp(0, size.height),
          ),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DetectionBoxPainter oldDelegate) {
    return oldDelegate.detections != detections ||
        oldDelegate.imageSize != imageSize;
  }
}
