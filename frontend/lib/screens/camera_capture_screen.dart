import 'dart:async';
import 'dart:math';
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:sensors_plus/sensors_plus.dart';

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
/// Returns the captured, cropped JPEG bytes via Navigator.pop, or null
/// if the user backs out without capturing.
class CameraCaptureScreen extends StatefulWidget {
  const CameraCaptureScreen({super.key});

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
        setState(() => _error = 'No camera found on this device.');
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
      setState(() => _error = 'Failed to start camera: $e');
    }
  }

  /// Cycles to the next flash mode and applies it to the camera.
  /// Works the same whether auto-capture is on or off.
  Future<void> _cycleFlashMode() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) return;

    final currentIndex = _flashModeCycle.indexOf(_flashMode);
    final nextMode = _flashModeCycle[(currentIndex + 1) % _flashModeCycle.length];

    try {
      await controller.setFlashMode(nextMode);
      if (!mounted) return;
      setState(() => _flashMode = nextMode);
      ScaffoldMessenger.of(context)
        ..hideCurrentSnackBar()
        ..showSnackBar(
          SnackBar(
            content: Text('Flash: ${_flashLabel(nextMode)}'),
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
            content: Text('Flash "${_flashLabel(nextMode)}" is not supported on this device'),
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
        return 'Off';
      case FlashMode.auto:
        return 'Auto';
      case FlashMode.always:
        return 'On';
      case FlashMode.torch:
        return 'Light (always on)';
    }
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
    final variance = _recentJitter
            .map((m) => (m - mean) * (m - mean))
            .reduce((a, b) => a + b) /
        _recentJitter.length;
    final stdDev = sqrt(variance);

    final percent =
        (100 * (1 - (stdDev / _maxJitterForZeroPercent))).clamp(0.0, 100.0);

    if (!mounted) return;
    setState(() => _stabilityPercent = percent);

    final now = DateTime.now();
    if (percent >= _autoCaptureThreshold) {
      _stableSince ??= now;
      final heldFor = now.difference(_stableSince!);
      if (_autoCaptureEnabled &&
          !_autoCaptureFired &&
          !_isCapturing &&
          heldFor >= _requiredHoldDuration) {
        _autoCaptureFired = true;
        _capture();
      }
    } else {
      _stableSince = null;
    }
  }

  /// Tap-to-focus: locks focus and exposure at the tapped point so the
  /// shot is sharp before capture, instead of relying on whatever the
  /// continuous autofocus happened to settle on.
  Future<void> _onTapToFocus(TapDownDetails details, BoxConstraints constraints) async {
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
        final laplacian = -4 * luminanceAt(x, y)
            + luminanceAt(x - 1, y) + luminanceAt(x + 1, y)
            + luminanceAt(x, y - 1) + luminanceAt(x, y + 1);
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
        title: const Text('Photo is too blurry'),
        content: const Text(
          'This photo looks blurry, which will make the handwriting '
          'hard to read correctly. Please hold the phone steady, make '
          'sure the page is well lit, and try again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Retake'),
          ),
        ],
      ),
    );
  }

  Future<void> _capture() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized || _isCapturing) return;

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
            const SnackBar(content: Text('Could not read the captured photo.')),
          );
        }
        return;
      }

      final oriented = img.bakeOrientation(decoded);

      final cropWidth = (oriented.width * _guideWidthFactor).round();
      final cropHeight = (oriented.height * _guideHeightFactor).round();
      final x = ((oriented.width - cropWidth) / 2).round();
      final y = ((oriented.height - cropHeight) / 2).round();
      final cropped = img.copyCrop(oriented, x: x, y: y, width: cropWidth, height: cropHeight);

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

      final croppedBytes = Uint8List.fromList(img.encodeJpg(cropped, quality: 95));
      if (!mounted) return;
      Navigator.of(context).pop<Uint8List>(croppedBytes);
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
          SnackBar(content: Text('Capture failed: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _accelSubscription?.cancel();
    // Make sure the torch doesn't stay on after leaving the screen.
    final controller = _controller;
    if (controller != null && controller.value.isInitialized && _flashMode == FlashMode.torch) {
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
        appBar: AppBar(title: const Text('Camera')),
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

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: FutureBuilder<void>(
          future: _initializeControllerFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator(color: Colors.white));
            }
            return LayoutBuilder(
              builder: (context, constraints) {
                return Stack(
                  fit: StackFit.expand,
                  children: [
                    GestureDetector(
                      onTapDown: (details) => _onTapToFocus(details, constraints),
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
                              border: Border.all(color: Colors.white70, width: 2),
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
                              border: Border.all(color: Colors.yellow, width: 2),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    Positioned(
                      top: 8,
                      left: 8,
                      child: IconButton(
                        icon: const Icon(Icons.close, color: Colors.white, size: 28),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    // Top-right controls: flash (always available) and
                    // auto-capture toggle. They are independent - the
                    // flash choice applies to every capture, manual or
                    // automatic.
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_flashSupported)
                            IconButton(
                              icon: Icon(
                                _flashIcon(_flashMode),
                                color: flashIsActive ? Colors.yellowAccent : Colors.white70,
                                size: 28,
                              ),
                              tooltip: 'Flash: ${_flashLabel(_flashMode)}',
                              onPressed: _isCapturing ? null : _cycleFlashMode,
                            ),
                          // Toggle for auto-capture, in case a user
                          // prefers to always capture manually.
                          IconButton(
                            icon: Icon(
                              _autoCaptureEnabled ? Icons.bolt : Icons.bolt_outlined,
                              color: _autoCaptureEnabled ? Colors.greenAccent : Colors.white70,
                              size: 28,
                            ),
                            tooltip: _autoCaptureEnabled ? 'Auto-capture on' : 'Auto-capture off',
                            onPressed: () {
                              setState(() {
                                _autoCaptureEnabled = !_autoCaptureEnabled;
                                _stableSince = null;
                                _autoCaptureFired = false;
                              });
                            },
                          ),
                        ],
                      ),
                    ),
                    Positioned(
                      bottom: 24,
                      left: 0,
                      right: 0,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_autoCaptureEnabled && !_isCapturing)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: Text(
                                isSteady
                                    ? 'Hold steady…'
                                    : 'Steadying: ${_stabilityPercent.round()}%',
                                style: TextStyle(
                                  color: isSteady ? Colors.greenAccent : Colors.white70,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          Center(
                            child: GestureDetector(
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
                                          value: (_stabilityPercent / 100).clamp(0.0, 1.0),
                                          strokeWidth: 4,
                                          backgroundColor: Colors.white24,
                                          valueColor: AlwaysStoppedAnimation<Color>(
                                            isSteady ? Colors.greenAccent : Colors.orangeAccent,
                                          ),
                                        ),
                                      ),
                                    Container(
                                      width: 72,
                                      height: 72,
                                      decoration: BoxDecoration(
                                        shape: BoxShape.circle,
                                        border: Border.all(color: Colors.white, width: 4),
                                        color: _isCapturing ? Colors.grey : Colors.white24,
                                      ),
                                      child: _isCapturing
                                          ? const Padding(
                                              padding: EdgeInsets.all(20),
                                              child: CircularProgressIndicator(color: Colors.white),
                                            )
                                          : null,
                                    ),
                                  ],
                                ),
                              ),
                            ),
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
    );
  }
}