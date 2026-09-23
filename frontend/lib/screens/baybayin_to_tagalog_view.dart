import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show applyBoxFit, FittedSizes;
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import '../services/api_service.dart';
import '../widgets/image_cropper_widget.dart';
import '../screens/camera_capture_screen.dart';
import '../screens/baybayin_result_screen.dart';

/// Handles the "Baybayin to Latin" mode: capture/upload a photo, crop it,
/// send it for translation, and show the result. Fully self-contained —
/// owns its own state, independent of the text-translation mode.
class BaybayinToTagalogView extends StatefulWidget {
  const BaybayinToTagalogView({super.key});

  @override
  State<BaybayinToTagalogView> createState() => _BaybayinToTagalogViewState();
}

class _BaybayinToTagalogViewState extends State<BaybayinToTagalogView> {
  final ApiService _apiService = ApiService();
  final ImagePicker _picker = ImagePicker();

  String _translatedResult = "Result will appear here";
  bool _isLoading = false;
  Uint8List? _webImage;

  // Bounding-box overlay state, populated from the API's
  // individual_detections + image_width/image_height fields.
  List<Map<String, dynamic>> _detections = [];
  double _imageWidth = 0;
  double _imageHeight = 0;

  // Which writing-instrument preset the backend should use for
  // stroke-gap / diacritic thresholds. 'marker' covers both thick
  // marker and pentel/felt-tip pens (they share the same tuned
  // thresholds); 'pen' is for thin ballpoint/gel ink, which needs an
  // adaptive, stroke-thickness-scaled gap threshold instead.
  String _inputType = 'marker';

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

  Future<void> _processCroppedImage(Uint8List imageBytes) async {
    setState(() {
      _isLoading = true;
      _translatedResult = 'Processing Image...';
      _detections = [];
    });

    final response = await _apiService.uploadAndTranslateDetailed(
      null,
      'Baybayin to Tagalog',
      imageBytes: imageBytes,
      inputType: _inputType,
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
        final lowResolutionWarning = response['low_resolution_warning'] as String?;
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
          Future.delayed(const Duration(milliseconds: 500), () {
            if (mounted) _showResults(imageBytes, response);
          });
        } else if (status == 'no_characters' || _translatedResult.isEmpty) {
          _translatedResult = 'No Baybayin letters found. Try a clearer crop.';
        }
      } else {
        _translatedResult = 'Error: Connection Failed';
      }
    });
  }

  /// Shared pipeline for BOTH capture sources: normalize orientation,
  /// let the user crop, then upload. Gallery and camera only differ in
  /// how they obtain rawBytes before reaching this point.
  Future<void> _handleRawImage(Uint8List rawBytes) async {
    if (!mounted) return;

    // Normalize orientation BEFORE cropping, so the crop UI itself
    // (and everything downstream of it) works against the same
    // pixel grid the backend will later compute boxes against.
    final bytes = _normalizeOrientation(rawBytes);

    final Uint8List? croppedBytes = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(
        builder: (_) => ImageCropperScreen(imageData: bytes),
      ),
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

    await _processCroppedImage(croppedBytes);
  }

  // ---- Blur detection (gallery path) ----
  // Mirrors camera_capture_screen.dart's _computeBlurScore exactly -
  // same Laplacian-variance metric, same threshold - so a gallery photo
  // gets the same immediate "too blurry, try again" feedback a camera
  // capture already gets, instead of only finding out after a full
  // upload round-trip to the backend's own blur check. This can't fix
  // a gallery photo's actual resolution or focus (those are baked into
  // the file already), but it DOES catch true blur (motion/focus
  // softness) before wasting time uploading it.
  static const double _galleryBlurVarianceThreshold = 60.0;

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

  Future<bool> _confirmRetakeIfBlurry(Uint8List bytes) async {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return false;

    final blurScore = _computeBlurScore(decoded);
    if (blurScore >= _galleryBlurVarianceThreshold) return false;

    if (!mounted) return true;
    await showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Photo is too blurry'),
        content: const Text(
          'This photo looks blurry, which will make the handwriting '
          'hard to read correctly. Try picking a sharper photo, or use '
          'the in-app camera instead for a steadier, higher-resolution '
          'capture.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    return true;
  }

  Future<void> _uploadFromGallery() async {
    // Gallery photos come from whatever camera app originally took
    // them - unlike CameraCaptureScreen, this app has no control over
    // the resolution or focus that photo was captured at, which can't
    // be fixed after the fact (see _confirmRetakeIfBlurry's own note
    // on this). Shown as a brief, non-blocking notice rather than a
    // dialog the person has to dismiss - it informs the choice without
    // getting in the way of it, since gallery upload is still a fully
    // legitimate option for a photo taken earlier or shared by someone
    // else.
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Tip: the in-app Camera locks focus and resolution for '
            'more reliable results. Gallery works too, but results can '
            'vary depending on how the photo was originally taken.',
          ),
          duration: Duration(seconds: 4),
        ),
      );
    }

    final XFile? photo = await _picker.pickImage(
      source: ImageSource.gallery,
      // No imageQuality / maxWidth / maxHeight: those silently
      // downscale and re-compress the file before it ever reaches the
      // app, which is exactly what breaks thin strokes. Keep the
      // gallery file at its native resolution and quality.
    );
    if (photo == null) return;

    final rawBytes = await photo.readAsBytes();

    // Checked BEFORE _handleRawImage (orientation-normalize -> crop ->
    // upload), so a blurry pick is caught immediately rather than
    // after the person has already gone through cropping and waited
    // for an upload, only for the backend to reject it.
    final isBlurry = await _confirmRetakeIfBlurry(rawBytes);
    if (isBlurry) return;

    await _handleRawImage(rawBytes);
  }

  /// Now uses the custom CameraCaptureScreen (camera package) instead
  /// of image_picker's OS camera, so we can force a high resolution
  /// preset and lock focus/exposure before capture - neither of which
  /// the OS camera app exposes to us.
  Future<void> _captureFromCamera() async {
    final Uint8List? captured = await Navigator.of(context).push<Uint8List>(
      MaterialPageRoute(builder: (_) => const CameraCaptureScreen()),
    );
    if (captured == null) return;

    await _handleRawImage(captured);
  }

  void _showResults(Uint8List sourceImage, Map<String, dynamic> data) {
    Navigator.of(context).push(
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

  Widget _buildImageDisplay() {
    final hasBoxes = !_isLoading &&
        _webImage != null &&
        _detections.isNotEmpty &&
        _imageWidth > 0 &&
        _imageHeight > 0;

    return Stack(
      children: [
        Center(
          child: _webImage != null
              ? Image.memory(_webImage!, fit: BoxFit.contain)
              : Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: const [
                      Icon(Icons.document_scanner, size: 64, color: Colors.brown),
                      SizedBox(height: 12),
                      Text(
                        "Upload or scan a document containing Baybayin scripts to transcribe",
                        textAlign: TextAlign.center,
                        style: TextStyle(color: Colors.grey, fontSize: 14),
                      ),
                    ],
                  ),
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
        if (_isLoading)
          Positioned.fill(
            child: ColoredBox(
              color: Colors.black.withOpacity(0.24),
              child: Center(
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: const [
                        CircularProgressIndicator(color: Colors.brown),
                        SizedBox(height: 12),
                        Text(
                          "Processing text algorithm...",
                          style: TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          )
        else if (_webImage != null)
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(12),
              color: Colors.black54,
              child: Text(
                _translatedResult,
                style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildUploadWidget() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.brown.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.photo_library, size: 28, color: Colors.brown),
        ),
        const SizedBox(height: 8),
        const Text("Gallery", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.black87)),
      ],
    );
  }

  Widget _buildCameraWidget() {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.brown.withOpacity(0.1),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.camera_alt, size: 28, color: Colors.brown),
        ),
        const SizedBox(height: 8),
        const Text("Camera", style: TextStyle(fontSize: 14, fontWeight: FontWeight.w500, color: Colors.black87)),
      ],
    );
  }

  /// Two-option segmented toggle for "Marker / Felt-tip" vs "Pen",
  /// controlling which stroke-gap preset the backend uses. Placed above
  /// the Gallery/Camera row so the user picks it before capturing.
  Widget _buildInputTypeToggle() {
    Widget buildOption(String value, String label, IconData icon) {
      final bool selected = _inputType == value;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _inputType = value),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: selected ? Colors.brown : Colors.brown.withOpacity(0.08),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 18, color: selected ? Colors.white : Colors.brown),
                const SizedBox(height: 4),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : Colors.brown,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Container(
        padding: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color: const Color(0xFFF5F5F5),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            buildOption('marker', 'Marker / Felt-tip', Icons.brush),
            const SizedBox(width: 4),
            buildOption('pen', 'Pen', Icons.edit),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 20),
            decoration: BoxDecoration(
              color: const Color(0xFFF5F5F5),
              borderRadius: BorderRadius.circular(15),
            ),
            clipBehavior: Clip.antiAlias,
            child: _buildImageDisplay(),
          ),
        ),
        const SizedBox(height: 16),
        _buildInputTypeToggle(),
        const SizedBox(height: 16),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 30),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              GestureDetector(onTap: _uploadFromGallery, child: _buildUploadWidget()),
              const SizedBox(width: 40),
              GestureDetector(onTap: _captureFromCamera, child: _buildCameraWidget()),
            ],
          ),
        ),
      ],
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
      ..color = const Color(0xFF00E676) // green
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
          Offset(rect.left, (rect.top - textPainter.height).clamp(0, size.height)),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DetectionBoxPainter oldDelegate) {
    return oldDelegate.detections != detections || oldDelegate.imageSize != imageSize;
  }
}