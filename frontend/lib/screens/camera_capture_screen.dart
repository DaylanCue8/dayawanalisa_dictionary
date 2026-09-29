import 'dart:async';
import 'dart:math';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:sensors_plus/sensors_plus.dart';

import '../services/app_language.dart';
import '../services/app_settings.dart';
import '../widgets/liquid_glass_selector.dart';

/// Custom camera capture screen (replaces the OS camera app for this
/// flow) so we can force a high resolution preset and lock focus/
/// exposure before capture - neither of which is possible when going
/// through image_picker's ImageSource.camera, since that hands control
/// entirely to the OS camera app.
///
/// The white guide box overlay is NOT just decorative - after capture,
/// the photo is orientation-normalized and auto-cropped to exactly that
/// box's area before being returned, so what the user framed is what
/// they get.
///
/// A blur check runs on the cropped photo before it's ever returned -
/// a photo that's too blurry to read reliably prompts a retake dialog
/// instead of being handed off as a usable result.
///
/// The user can choose a flash mode (off / auto / on / torch). The
/// chosen mode applies to EVERY capture - both the manual shutter
/// button and stability-based auto-capture - since both go through
/// the same _capture() -> takePicture() call.
///
/// Multi-page mode keeps the camera open: every capture (manual or
/// auto) is added as a page after the same crop + blur check, and "Done"
/// returns them all at once.
///
/// Returns the captured, cropped JPEG bytes and selected input type via
/// Navigator.pop, or null if the user backs out without capturing.
class CameraCaptureResult {
  /// The first (or only) page.
  final Uint8List imageBytes;
  final String inputType;

  /// Every page in capture order; just [imageBytes] for a single shot.
  final List<Uint8List> pages;

  CameraCaptureResult({
    required this.imageBytes,
    required this.inputType,
    List<Uint8List>? pages,
  }) : pages = pages ?? [imageBytes];

  bool get isMultiPage => pages.length > 1;
}

class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

  /// Most pages one multi-page scan can hold (memory + reading time).
  static const int maxPages = 10;

  @override
  State<CameraCaptureScreen> createState() => _CameraCaptureScreenState();
}

class _CameraCaptureScreenState extends State<CameraCaptureScreen> {
  CameraController? _controller;
  Future<void>? _initializeControllerFuture;
  bool _isCapturing = false;
  Offset? _focusPoint;
  String? _error;

  // Guide box size as fractions of the screen - MUST match the
  // FractionallySizedBox values in the overlay below, since these
  // same fractions are applied directly to the captured image to crop
  // it to what the box outlined.
  static const double _guideWidthFactor = 0.85;
  static const double _guideHeightFactor = 0.5;

  // ---- Flash ----
  // Tapping the flash button cycles through these modes in order:
  //   off    - never fire the flash
  //   auto   - the camera decides based on the light level
  //   always - fire the flash on every capture
  //   torch  - keep the light ON continuously, so the user can see the
  //            lit page in the preview before capturing (often the best
  //            choice for a document in a dim room - fewer surprises
  //            than a flash that only fires at the last instant)
  // Starts OFF: a flash on paper can create glare/hot spots that wash
  // out thin pen strokes, so it should be the user's choice.
  static const List<FlashMode> _flashModeCycle = [
    FlashMode.off,
    FlashMode.auto,
    FlashMode.always,
    FlashMode.torch,
  ];
  FlashMode _flashMode = FlashMode.off;
  bool _flashSupported = true;

  // ---- Blur detection ----
  // STARTING ESTIMATE - not yet calibrated. Take several genuinely
  // sharp and several genuinely blurry photos on your real test
  // devices, print the resulting _computeBlurScore values, and set
  // this threshold from the real gap between those two groups. Mirrors
  // the same Laplacian-variance metric used server-side, so a photo
  // judged "sharp enough" here should also pass the backend's check.
  static const double _blurVarianceThreshold = 60.0;

  // ---- Stability-based auto-capture ----
  // Shaky hands are the single biggest cause of a blurry document
  // photo, and asking the user to press a physical/on-screen button
  // is itself a way to introduce a last-instant jolt right as the
  // shutter fires. Instead, userAccelerometerEvents (acceleration with
  // gravity already filtered out, so it reads ~0 when the phone is
  // truly still regardless of how it's tilted) is watched continuously;
  // its jitter over a short rolling window is converted into a 0-100%
  // "steadiness" score, and the shutter fires automatically once that
  // score holds at/above the threshold for a sustained moment - not
  // just a single lucky instant, which would trigger on a brief
  // coincidental dip mid-shake rather than genuine stillness. The
  // manual tap-to-capture button keeps working at all times regardless.
  StreamSubscription<UserAccelerometerEvent>? _accelSubscription;
  final List<double> _recentJitter = [];
  static const int _jitterWindowSize = 20;
  // Calibration knob: the jitter (m/s^2 std-dev) that counts as 0%
  // steady. Tune this against real devices/hands - a lower value makes
  // the meter more sensitive (reaches 100% only when very still); a
  // higher value makes it easier to reach 100%.
  static const double _maxJitterForZeroPercent = 1.2;
  static const double _autoCaptureThreshold = 95.0;
  static const Duration _requiredHoldDuration = Duration(milliseconds: 700);
  DateTime? _stableSince;
  double _stabilityPercent = 0.0;
  bool _autoCaptureEnabled = true;
  bool _autoCaptureFired = false;
  // Starting values come from Settings.
  String _cameraInputType = AppSettings.instance.cameraInputType;
  bool _gridEnabled = AppSettings.instance.cameraGridByDefault;
  bool _multiPageEnabled = false;

  // ---- Multi-page ----
  // Pages captured so far in this session (cropped JPEGs, in order).
  final List<Uint8List> _pages = [];
  static const int _maxPages = CameraCaptureScreen.maxPages;
  bool get _atPageLimit => _multiPageEnabled && _pages.length >= _maxPages;
  // After a page is added, auto-capture stays spent until the phone
  // moves (steadiness drops below the threshold) - i.e. the user is
  // lining up the next page - so it can't fire twice on the same one.
  bool _rearmAfterMovement = false;

  static const Color _accentColor = Color(0xFFFFFF00);

  @override
  void initState() {
    super.initState();
    _setupCamera();
    _startStabilityMonitoring();
  }

  Future<void> _setupCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(
          () => _error = tr(
            'No camera found on this device.',
            'Walang nakitang kamera sa device na ito.',
          ),
        );
        return;
      }
      final backCamera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      // max gives the most pixels per letter, which matters most when
      // the page is photographed from further away (thin strokes and
      // small kudlit marks survive thresholding better).
      final controller = CameraController(
        backCamera,
        ResolutionPreset.max,
        enableAudio: false,
        imageFormatGroup: ImageFormatGroup.jpeg,
      );

      _controller = controller;
      _initializeControllerFuture = controller.initialize().then((_) async {
        try {
          await controller.setFocusMode(FocusMode.auto);
          await controller.setExposureMode(ExposureMode.auto);
        } catch (_) {
          // Some devices/plugin versions don't support manual focus
          // mode changes - safe to ignore, autofocus still runs.
        }
        // Apply the starting flash mode. If the device has no flash
        // (or the plugin refuses), hide the flash button entirely.
        try {
          await controller.setFlashMode(_flashMode);
        } catch (_) {
          _flashSupported = false;
        }
        if (mounted) setState(() {});
      });
      setState(() {});
    } catch (e) {
      setState(
        () => _error = tr(
          'Failed to start camera: $e',
          'Hindi mabuksan ang kamera: $e',
        ),
      );
    }
  }

  /// Cycles to the next flash mode and applies it to the camera.
  /// Works the same whether auto-capture is on or off.
  Future<void> _cycleFlashMode() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final currentIndex = _flashModeCycle.indexOf(_flashMode);
    final nextMode =
        _flashModeCycle[(currentIndex + 1) % _flashModeCycle.length];

    try {
      await controller.setFlashMode(nextMode);
      if (!mounted) return;
      setState(() => _flashMode = nextMode);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('${tr('Flash', 'Flash')}: ${_flashLabel(nextMode)}'),
            duration: const Duration(milliseconds: 900),
          ),
        );
    } catch (_) {
      // This particular mode isn't supported on this device (torch is
      // the most common one missing). Skip past it on the next tap.
      if (!mounted) return;
      setState(() => _flashMode = nextMode);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text(
              tr(
                'Flash "${_flashLabel(nextMode)}" is not supported on this device',
                'Hindi suportado ng device na ito ang flash na "${_flashLabel(nextMode)}"',
              ),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
    }
  }

  IconData _flashIcon(FlashMode mode) {
    switch (mode) {
      case FlashMode.off:
        return Icons.flash_off;
      case FlashMode.auto:
        return Icons.flash_auto;
      case FlashMode.always:
        return Icons.flash_on;
      case FlashMode.torch:
        return Icons.highlight;
    }
  }

  String _flashLabel(FlashMode mode) {
    switch (mode) {
      case FlashMode.off:
        return tr('Off', 'Patay');
      case FlashMode.auto:
        return tr('Auto', 'Awtomatiko');
      case FlashMode.always:
        return tr('On', 'Bukas');
      case FlashMode.torch:
        return tr('Light (always on)', 'Ilaw (laging bukas)');
    }
  }

  Widget _buildCameraLogo() {
    return Image.asset(
      'assets/images/dayawlogo.png',
      height: 42,
      errorBuilder: (context, error, stackTrace) => const Text(
        'DAYAW',
        style: TextStyle(
          color: Colors.white,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildTopControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton.icon(
            onPressed: () => setState(() => _gridEnabled = !_gridEnabled),
            style: ButtonStyle(
              foregroundColor: WidgetStatePropertyAll(
                _gridEnabled ? _accentColor : Colors.white,
              ),
              overlayColor: WidgetStatePropertyAll(
                _accentColor.withValues(alpha: 0.2),
              ),
            ),
            icon: Icon(
              Icons.grid_4x4,
              color: _gridEnabled ? _accentColor : Colors.white70,
              size: 18,
            ),
            label: Text(context.tr('Grid', 'Grid')),
          ),
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(12),
            ),
            // Tap, or long-press / drag the yellow pill, to switch.
            child: SizedBox(
              width: 132,
              child: LiquidGlassSelector(
                count: _inputTypes.length,
                selectedIndex: _inputTypes.indexWhere(
                  (t) => t.$1 == _cameraInputType,
                ),
                height: 32,
                onChanged: (i) =>
                    setState(() => _cameraInputType = _inputTypes[i].$1),
                itemBuilder: (context, i, selectedness) => Text(
                  context.tr(_inputTypes[i].$2, _inputTypes[i].$3),
                  style: TextStyle(
                    color: Color.lerp(
                      Colors.white70,
                      Colors.black87,
                      selectedness,
                    ),
                    fontWeight: FontWeight.w600,
                    fontSize: 12,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // (key, English, Filipino)
  static const List<(String, String, String)> _inputTypes = [
    ('marker', 'Marker', 'Marker'),
    ('pen', 'Pen', 'Bolpen'),
  ];

  Widget _buildBottomControl({
    required IconData icon,
    required String label,
    required VoidCallback? onPressed,
    bool active = false,
  }) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 52,
          height: 52,
          decoration: BoxDecoration(
            color: active ? Colors.white : Colors.black54,
            shape: BoxShape.circle,
          ),
          child: IconButton(
            tooltip: label,
            onPressed: onPressed,
            style: ButtonStyle(
              overlayColor: WidgetStatePropertyAll(
                _accentColor.withValues(alpha: 0.3),
              ),
            ),
            icon: Icon(
              icon,
              color: active ? Colors.black87 : Colors.white,
              size: 24,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _buildMultiPageControl() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
      decoration: BoxDecoration(
        color: _multiPageEnabled ? _accentColor : Colors.black54,
        borderRadius: BorderRadius.circular(16),
      ),
      child: TextButton.icon(
        onPressed: _toggleMultiPage,
        style: ButtonStyle(
          foregroundColor: WidgetStatePropertyAll(
            _multiPageEnabled ? Colors.black87 : Colors.white,
          ),
          overlayColor: WidgetStatePropertyAll(
            _accentColor.withValues(alpha: 0.25),
          ),
        ),
        icon: Icon(
          Icons.library_add,
          color: _multiPageEnabled ? Colors.black87 : Colors.white,
          size: 20,
        ),
        label: Text(
          context.tr('Multi-page', 'Maraming pahina'),
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }

  Future<void> _toggleMultiPage() async {
    if (_multiPageEnabled && _pages.isNotEmpty) {
      if (!await _confirmDiscardPages()) return;
      _pages.clear();
    }
    if (!mounted) return;
    setState(() {
      _multiPageEnabled = !_multiPageEnabled;
      _rearmAfterMovement = false;
      _autoCaptureFired = false;
      _stableSince = null;
    });
  }

  Future<bool> _confirmDiscardPages() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          context.tr(
            'Discard ${_pages.length} '
                '${_pages.length == 1 ? 'page' : 'pages'}?',
            'Itapon ang ${_pages.length} pahina?',
          ),
        ),
        content: Text(
          context.tr(
            'The pages you captured will be lost.',
            'Mawawala ang mga pahinang kinuhanan mo.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.tr('Keep', 'Itabi')),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.tr('Discard', 'Itapon')),
          ),
        ],
      ),
    );
    return discard == true;
  }

  Future<void> _close() async {
    if (_pages.isNotEmpty && !await _confirmDiscardPages()) return;
    if (mounted) Navigator.of(context).pop();
  }

  void _finishMultiPage() {
    if (_pages.isEmpty) return;
    Navigator.of(context).pop<CameraCaptureResult>(
      CameraCaptureResult(
        imageBytes: _pages.first,
        inputType: _cameraInputType,
        pages: List.of(_pages),
      ),
    );
  }

  void _removePage(int index) {
    setState(() => _pages.removeAt(index));
  }

  /// Thumbnails of the pages captured so far; tap the x to remove one.
  Widget _buildPageStrip() {
    return SizedBox(
      height: 76,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _pages.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) => Stack(
          clipBehavior: Clip.none,
          children: [
            Container(
              width: 54,
              height: 72,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white, width: 2),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  _pages[i],
                  fit: BoxFit.cover,
                  cacheWidth: 160,
                  gaplessPlayback: true,
                ),
              ),
            ),
            Positioned(
              left: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${i + 1}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            Positioned(
              right: -6,
              top: -6,
              child: GestureDetector(
                onTap: () => _removePage(i),
                child: Container(
                  width: 22,
                  height: 22,
                  decoration: const BoxDecoration(
                    color: Colors.black87,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, color: Colors.white, size: 14),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Shown when the 10th page is added, and whenever another capture is
  /// attempted while full. Offers to read the pages right away.
  Future<void> _showPageLimitDialog() async {
    if (!mounted) return;
    final readNow = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        icon: const Icon(Icons.auto_stories_outlined),
        title: Text(
          context.tr('Page limit reached', 'Naabot na ang limitasyon'),
        ),
        content: Text(
          context.tr(
            'You have $_maxPages of $_maxPages pages, the most one scan can '
                'hold. Read them now, or remove a page to take another.',
            'Mayroon ka nang $_maxPages sa $_maxPages pahina, ang pinakamarami '
                'sa isang scan. Basahin na ang mga ito, o mag-alis ng pahina '
                'para kumuha ng bago.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.tr('Review pages', 'Suriin ang mga pahina')),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.tr('Read pages', 'Basahin ang mga pahina')),
          ),
        ],
      ),
    );
    if (readNow == true) _finishMultiPage();
  }

  /// "Done" pill next to the shutter, shown once a page is captured.
  Widget _buildDoneButton() {
    return GestureDetector(
      onTap: _isCapturing ? null : _finishMultiPage,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _accentColor,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.check, color: Colors.black87, size: 18),
            const SizedBox(width: 4),
            Text(
              '${context.tr('Done', 'Tapos')} · ${_pages.length}/$_maxPages',
              style: const TextStyle(
                color: Colors.black87,
                fontWeight: FontWeight.w800,
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Starts listening to device motion for the auto-capture stability
  /// meter. If the sensor is unavailable on this device/platform, the
  /// listener simply never fires - auto-capture stays inert and the
  /// manual shutter button is unaffected either way.
  void _startStabilityMonitoring() {
    _accelSubscription = userAccelerometerEvents.listen(
      _onAccelerometerEvent,
      onError: (_) {},
      cancelOnError: true,
    );
  }

  void _onAccelerometerEvent(UserAccelerometerEvent event) {
    final magnitude = sqrt(
      event.x * event.x + event.y * event.y + event.z * event.z,
    );

    _recentJitter.add(magnitude);
    if (_recentJitter.length > _jitterWindowSize) {
      _recentJitter.removeAt(0);
    }
    // Wait for a full window before scoring, so the very first few
    // readings right after opening the camera don't produce a
    // misleadingly high or low percentage from too little data.
    if (_recentJitter.length < _jitterWindowSize) return;

    final mean = _recentJitter.reduce((a, b) => a + b) / _recentJitter.length;
    final variance =
        _recentJitter
            .map((m) => (m - mean) * (m - mean))
            .reduce((a, b) => a + b) /
        _recentJitter.length;
    final stdDev = sqrt(variance);

    final percent = (100 * (1 - (stdDev / _maxJitterForZeroPercent))).clamp(
      0.0,
      100.0,
    );

    if (!mounted) return;
    setState(() => _stabilityPercent = percent);

    final now = DateTime.now();
    if (percent >= _autoCaptureThreshold) {
      _stableSince ??= now;
      final heldFor = now.difference(_stableSince!);
      if (_autoCaptureEnabled &&
          !_autoCaptureFired &&
          !_isCapturing &&
          // Full: don't keep auto-firing into the limit notice.
          !_atPageLimit &&
          heldFor >= _requiredHoldDuration) {
        _autoCaptureFired = true;
        _capture();
      }
    } else {
      _stableSince = null;
      if (_rearmAfterMovement) {
        _rearmAfterMovement = false;
        _autoCaptureFired = false;
      }
    }
  }

  /// Tap-to-focus: locks focus and exposure at the tapped point so the
  /// shot is sharp before capture, instead of relying on whatever the
  /// continuous autofocus happened to settle on.
  Future<void> _onTapToFocus(
    TapDownDetails details,
    BoxConstraints constraints,
  ) async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final normalized = Offset(
      details.localPosition.dx / constraints.maxWidth,
      details.localPosition.dy / constraints.maxHeight,
    );
    setState(() => _focusPoint = details.localPosition);

    try {
      await controller.setFocusPoint(normalized);
      await controller.setExposurePoint(normalized);
      await controller.setFocusMode(FocusMode.locked);
    } catch (_) {
      // Not all devices support point focus - ignore and fall back to
      // whatever focus the camera already has.
    }
  }

  /// Laplacian-variance sharpness score, computed on a downsized
  /// grayscale copy for speed. Higher = sharper. Mirrors the same
  /// metric used server-side (cv2.Laplacian(...).var()), so a photo
  /// judged "sharp enough" here should also pass the backend's check.
  double _computeBlurScore(img.Image image) {
    final resized = img.copyResize(image, width: 600);
    final gray = img.grayscale(resized);
    final width = gray.width;
    final height = gray.height;

    double sum = 0.0;
    double sumSq = 0.0;
    int count = 0;

    int luminanceAt(int x, int y) => gray.getPixel(x, y).r.toInt();

    for (int y = 1; y < height - 1; y++) {
      for (int x = 1; x < width - 1; x++) {
        final laplacian =
            -4 * luminanceAt(x, y) +
            luminanceAt(x - 1, y) +
            luminanceAt(x + 1, y) +
            luminanceAt(x, y - 1) +
            luminanceAt(x, y + 1);
        sum += laplacian;
        sumSq += laplacian * laplacian;
        count++;
      }
    }

    if (count == 0) return 0.0;
    final mean = sum / count;
    return (sumSq / count) - (mean * mean);
  }

  Future<void> _showBlurryRetakeDialog(double score) async {
    if (!mounted) return;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(context.tr('Photo is too blurry', 'Malabo ang larawan')),
        content: Text(
          context.tr(
            'This photo looks blurry, which will make the handwriting '
                'hard to read correctly. Please hold the phone steady, make '
                'sure the page is well lit, and try again.',
            'Malabo ang larawang ito, kaya mahihirapang basahin nang tama '
                'ang sulat-kamay. Hawakan nang matatag ang phone, siguraduhing '
                'maliwanag ang pahina, at subukan muli.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(context.tr('Retake', 'Kunan muli')),
          ),
        ],
      ),
    );
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isCapturing)
      return;
    if (_atPageLimit) {
      await _showPageLimitDialog();
      return;
    }

    setState(() => _isCapturing = true);
    try {
      // takePicture() uses whatever flash mode is currently set, so the
      // user's flash choice applies to manual AND auto-capture alike.
      final XFile file = await controller.takePicture();
      final rawBytes = await file.readAsBytes();

      final decoded = img.decodeImage(rawBytes);
      if (decoded == null) {
        if (mounted) {
          setState(() {
            _isCapturing = false;
            _autoCaptureFired = false;
            _stableSince = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                tr(
                  'Could not read the captured photo.',
                  'Hindi mabasa ang kinuhang larawan.',
                ),
              ),
            ),
          );
        }
        return;
      }

      final oriented = img.bakeOrientation(decoded);

      final cropWidth = (oriented.width * _guideWidthFactor).round();
      final cropHeight = (oriented.height * _guideHeightFactor).round();
      final x = ((oriented.width - cropWidth) / 2).round();
      final y = ((oriented.height - cropHeight) / 2).round();
      final cropped = img.copyCrop(
        oriented,
        x: x,
        y: y,
        width: cropWidth,
        height: cropHeight,
      );

      final blurScore = _computeBlurScore(cropped);
      if (blurScore < _blurVarianceThreshold) {
        if (mounted) {
          setState(() {
            _isCapturing = false;
            _autoCaptureFired = false;
            _stableSince = null;
          });
          await _showBlurryRetakeDialog(blurScore);
        }
        return; // stay on the camera screen - do NOT pop
      }

      final croppedBytes = Uint8List.fromList(
        img.encodeJpg(cropped, quality: 95),
      );
      if (!mounted) return;
      if (_multiPageEnabled) {
        setState(() {
          _pages.add(croppedBytes);
          _isCapturing = false;
          // Spent until the phone moves on to the next page.
          _autoCaptureFired = true;
          _rearmAfterMovement = true;
          _stableSince = null;
        });
        final count = _pages.length;
        final left = _maxPages - count;
        ScaffoldMessenger.of(context).hideCurrentSnackBar();
        if (left <= 0) {
          // Just hit the limit: say so right away, not on the next tap.
          if (AppSettings.instance.hapticsEnabled) {
            HapticFeedback.heavyImpact();
          }
          await _showPageLimitDialog();
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              left == 1
                  ? tr(
                      'Page $count added. 1 page left.',
                      'Naidagdag ang pahina $count. 1 pahina na lang.',
                    )
                  : tr(
                      'Page $count of $_maxPages added',
                      'Naidagdag ang pahina $count ng $_maxPages',
                    ),
            ),
            duration: Duration(milliseconds: left == 1 ? 2000 : 900),
          ),
        );
        return;
      }
      Navigator.of(context).pop<CameraCaptureResult>(
        CameraCaptureResult(
          imageBytes: croppedBytes,
          inputType: _cameraInputType,
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isCapturing = false;
          // Capture failed, so the user is still on this screen -
          // allow another auto-capture attempt once stability is
          // re-established, rather than leaving auto-capture
          // permanently spent for the rest of this session.
          _autoCaptureFired = false;
          _stableSince = null;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              tr('Capture failed: $e', 'Hindi nakakuha ng larawan: $e'),
            ),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _accelSubscription?.cancel();
    // Make sure the torch doesn't stay on after leaving the screen.
    final controller = _controller;
    if (controller != null &&
        controller.value.isInitialized &&
        _flashMode == FlashMode.torch) {
      controller.setFlashMode(FlashMode.off).catchError((_) {});
    }
    controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(title: Text(context.tr('Camera', 'Kamera'))),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              _error!,
              style: const TextStyle(color: Colors.white),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final controller = _controller;
    if (controller == null || _initializeControllerFuture == null) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator(color: Colors.white)),
      );
    }

    final isSteady = _stabilityPercent >= _autoCaptureThreshold;
    final flashIsActive = _flashMode != FlashMode.off;

    return PopScope(
      canPop: _pages.isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: SafeArea(
          child: FutureBuilder<void>(
            future: _initializeControllerFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(
                  child: CircularProgressIndicator(color: Colors.white),
                );
              }
              return LayoutBuilder(
                builder: (context, constraints) {
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      GestureDetector(
                        onTapDown: (details) =>
                            _onTapToFocus(details, constraints),
                        child: CameraPreview(controller),
                      ),
                      // Framing guide - this is now the ACTUAL crop
                      // boundary, applied to the captured photo right
                      // after takePicture(). Keep _guideWidthFactor /
                      // _guideHeightFactor above in sync with these
                      // FractionallySizedBox values if you change either.
                      IgnorePointer(
                        child: Center(
                          child: FractionallySizedBox(
                            widthFactor: _guideWidthFactor,
                            heightFactor: _guideHeightFactor,
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Colors.white70,
                                  width: 2,
                                ),
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                          ),
                        ),
                      ),
                      if (_focusPoint != null)
                        Positioned(
                          left: _focusPoint!.dx - 20,
                          top: _focusPoint!.dy - 20,
                          child: IgnorePointer(
                            child: Container(
                              width: 40,
                              height: 40,
                              decoration: BoxDecoration(
                                border: Border.all(
                                  color: Colors.yellow,
                                  width: 2,
                                ),
                                shape: BoxShape.circle,
                              ),
                            ),
                          ),
                        ),
                      Positioned(
                        top: 8,
                        left: 8,
                        child: IconButton(
                          icon: const Icon(
                            Icons.close,
                            color: Colors.white,
                            size: 28,
                          ),
                          onPressed: _close,
                        ),
                      ),
                      Positioned(
                        top: 10,
                        left: 0,
                        right: 0,
                        child: Center(child: _buildCameraLogo()),
                      ),
                      Positioned(
                        top: 58,
                        left: 0,
                        right: 0,
                        child: Center(child: _buildTopControls()),
                      ),
                      Positioned(
                        bottom: 24,
                        left: 0,
                        right: 0,
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_multiPageEnabled && _pages.isNotEmpty) ...[
                              _buildPageStrip(),
                              const SizedBox(height: 12),
                            ],
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (_flashSupported)
                                  _buildBottomControl(
                                    icon: _flashIcon(_flashMode),
                                    label: context.tr(
                                      'Flashlight',
                                      'Flashlight',
                                    ),
                                    active: flashIsActive,
                                    onPressed: _isCapturing
                                        ? null
                                        : _cycleFlashMode,
                                  ),
                                const SizedBox(width: 16),
                                _buildBottomControl(
                                  icon: _autoCaptureEnabled
                                      ? Icons.bolt
                                      : Icons.bolt_outlined,
                                  label: context.tr(
                                    'Auto-detect',
                                    'Awtomatiko',
                                  ),
                                  active: _autoCaptureEnabled,
                                  onPressed: () {
                                    setState(() {
                                      _autoCaptureEnabled =
                                          !_autoCaptureEnabled;
                                      _stableSince = null;
                                      _autoCaptureFired = false;
                                    });
                                  },
                                ),
                                const SizedBox(width: 16),
                                _buildMultiPageControl(),
                              ],
                            ),
                            const SizedBox(height: 14),
                            if (_atPageLimit)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(
                                  context.tr(
                                    'Page limit reached ($_maxPages/$_maxPages)',
                                    'Naabot na ang limitasyon ($_maxPages/$_maxPages)',
                                  ),
                                  style: const TextStyle(
                                    color: Colors.orangeAccent,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              )
                            else if (_autoCaptureEnabled && !_isCapturing)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(
                                  isSteady
                                      ? context.tr(
                                          'Hold steady…',
                                          'Huwag gumalaw…',
                                        )
                                      : context.tr(
                                          'Steadying: ${_stabilityPercent.round()}%',
                                          'Pinapatatag: ${_stabilityPercent.round()}%',
                                        ),
                                  style: TextStyle(
                                    color: isSteady
                                        ? Colors.greenAccent
                                        : Colors.white70,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            Row(
                              children: [
                                const Expanded(child: SizedBox()),
                                GestureDetector(
                                  onTap: _isCapturing ? null : _capture,
                                  child: SizedBox(
                                    width: 84,
                                    height: 84,
                                    child: Stack(
                                      alignment: Alignment.center,
                                      children: [
                                        if (_autoCaptureEnabled)
                                          SizedBox(
                                            width: 84,
                                            height: 84,
                                            child: CircularProgressIndicator(
                                              value: (_stabilityPercent / 100)
                                                  .clamp(0.0, 1.0),
                                              strokeWidth: 4,
                                              backgroundColor: Colors.white24,
                                              valueColor:
                                                  AlwaysStoppedAnimation<Color>(
                                                    isSteady
                                                        ? Colors.greenAccent
                                                        : Colors.orangeAccent,
                                                  ),
                                            ),
                                          ),
                                        Container(
                                          width: 72,
                                          height: 72,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: Colors.white,
                                              width: 4,
                                            ),
                                            color: _isCapturing || _atPageLimit
                                                ? Colors.grey
                                                : Colors.white24,
                                          ),
                                          child: _isCapturing
                                              ? const Padding(
                                                  padding: EdgeInsets.all(20),
                                                  child:
                                                      CircularProgressIndicator(
                                                        color: Colors.white,
                                                      ),
                                                )
                                              : _atPageLimit
                                              ? const Icon(
                                                  Icons.lock_outline,
                                                  color: Colors.white,
                                                  size: 28,
                                                )
                                              : null,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: Center(
                                    child:
                                        _multiPageEnabled && _pages.isNotEmpty
                                        ? _buildDoneButton()
                                        : const SizedBox(),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    );
  }
}
