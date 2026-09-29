import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

/// Document-style border adjustment: 4 corner handles that move
/// independently, so the border can follow the paper's real sides even
/// when the photo was taken at an angle (the paper then looks like a
/// slanted 4-sided shape, not a rectangle). On Apply, the selected area
/// is straightened into a flat rectangle.
///
/// The corners START around the detected writing (or on the paper if no
/// writing is found, or the whole image if no paper either). Returns the straightened JPEG bytes via
/// Navigator.pop, or null if the user closes the screen.
class ImageCropperScreen extends StatefulWidget {
  final Uint8List imageData;

  const ImageCropperScreen({super.key, required this.imageData});

  @override
  State<ImageCropperScreen> createState() => _ImageCropperScreenState();
}

class _ImageCropperScreenState extends State<ImageCropperScreen> {
  bool _isDetecting = true;
  bool _isCropping = false;
  String _detectMode = 'none'; // 'text', 'paper' or 'none'

  // Image size (after EXIF orientation) and the 4 corners in IMAGE pixels:
  // [topLeft, topRight, bottomRight, bottomLeft]
  double _imageWidth = 1;
  double _imageHeight = 1;
  List<Offset> _corners = [];
  int? _draggingCorner;

  static const double _handleRadius = 14;
  static const double _grabRadius = 40; // how close a touch must be to grab a corner

  @override
  void initState() {
    super.initState();
    _detect();
  }

  Future<void> _detect() async {
    Map<String, dynamic>? result;
    try {
      final Map<String, dynamic> r = await compute(detectPaperCorners, widget.imageData);
      result = r;
      debugPrint('[CROPPER] mode=${r['mode']} '
          'size=${r['width']}x${r['height']} quad=${r['quad']}');
    } catch (e, st) {
      debugPrint('[CROPPER] detection failed: $e\n$st');
      result = null;
    }
    if (!mounted) return;
    setState(() {
      if (result != null) {
        _imageWidth = (result['width'] as num).toDouble();
        _imageHeight = (result['height'] as num).toDouble();
        final quad = result['quad'] as List?;
        if (quad != null) {
          _corners = [
            for (final p in quad)
              Offset((p[0] as num).toDouble(), (p[1] as num).toDouble())
          ];
          _detectMode = (result['mode'] as String?) ?? 'none';
        }
      }
      if (_corners.length != 4) _corners = _fullImageCorners();
      _isDetecting = false;
    });
  }

  List<Offset> _fullImageCorners() => [
        const Offset(0, 0),
        Offset(_imageWidth, 0),
        Offset(_imageWidth, _imageHeight),
        Offset(0, _imageHeight),
      ];

  Future<void> _apply() async {
    setState(() => _isCropping = true);
    Uint8List? cropped;
    try {
      cropped = await compute(rectifyQuad, {
        'bytes': widget.imageData,
        'quad': [
          for (final c in _corners) [c.dx, c.dy]
        ],
      });
    } catch (_) {
      cropped = null;
    }
    if (!mounted) return;
    if (cropped == null) {
      setState(() => _isCropping = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not crop the image. Please try again.')),
      );
      return;
    }
    Navigator.of(context).pop(cropped);
  }

  // ---- image <-> screen coordinates (image is shown with BoxFit.contain) ----
  Rect _displayRect(Size box) {
    final scale = math.min(box.width / _imageWidth, box.height / _imageHeight);
    final w = _imageWidth * scale;
    final h = _imageHeight * scale;
    return Rect.fromLTWH((box.width - w) / 2, (box.height - h) / 2, w, h);
  }

  Offset _toScreen(Offset p, Rect r) => Offset(
        r.left + p.dx / _imageWidth * r.width,
        r.top + p.dy / _imageHeight * r.height,
      );

  Offset _toImage(Offset s, Rect r) => Offset(
        ((s.dx - r.left) / r.width * _imageWidth).clamp(0.0, _imageWidth),
        ((s.dy - r.top) / r.height * _imageHeight).clamp(0.0, _imageHeight),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        elevation: 0,
        title: const Text('Adjust Border', style: TextStyle(color: Colors.white)),
        leading: IconButton(
          icon: const Icon(Icons.close, color: Colors.white),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            tooltip: 'Use whole image',
            icon: const Icon(Icons.fullscreen, color: Colors.white),
            onPressed: (_isDetecting || _isCropping)
                ? null
                : () => setState(() => _corners = _fullImageCorners()),
          ),
          TextButton(
            onPressed: (_isDetecting || _isCropping) ? null : _apply,
            child: const Text('Apply', style: TextStyle(color: Colors.white, fontSize: 16)),
          ),
        ],
      ),
      body: SafeArea(
        child: _isDetecting
            ? const Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Colors.white),
                    SizedBox(height: 12),
                    Text('Finding the paper…', style: TextStyle(color: Colors.white70)),
                  ],
                ),
              )
            : Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
                    child: Text(
                      _detectMode == 'text'
                          ? 'Writing detected - drag the corners to adjust'
                          : _detectMode == 'paper'
                              ? 'Paper detected - drag the corners to adjust'
                              : 'Drag the corners around the writing',
                      style: const TextStyle(color: Colors.white, fontSize: 13),
                      textAlign: TextAlign.center,
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      // room so the handles are never cut off at the edges
                      padding: const EdgeInsets.all(_handleRadius + 6),
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final box = Size(constraints.maxWidth, constraints.maxHeight);
                          final rect = _displayRect(box);
                          final screenCorners = [for (final c in _corners) _toScreen(c, rect)];

                          return GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onPanStart: (d) {
                              int? nearest;
                              double best = _grabRadius;
                              for (int i = 0; i < 4; i++) {
                                final dist = (screenCorners[i] - d.localPosition).distance;
                                if (dist < best) {
                                  best = dist;
                                  nearest = i;
                                }
                              }
                              setState(() => _draggingCorner = nearest);
                            },
                            onPanUpdate: (d) {
                              final i = _draggingCorner;
                              if (i == null || _isCropping) return;
                              setState(() {
                                _corners = List.of(_corners)
                                  ..[i] = _toImage(d.localPosition, rect);
                              });
                            },
                            onPanEnd: (_) => setState(() => _draggingCorner = null),
                            child: Stack(
                              children: [
                                Positioned.fromRect(
                                  rect: rect,
                                  child: Image.memory(widget.imageData, fit: BoxFit.fill),
                                ),
                                Positioned.fill(
                                  child: CustomPaint(
                                    painter: _QuadPainter(
                                      corners: screenCorners,
                                      imageRect: rect,
                                      activeCorner: _draggingCorner,
                                      handleRadius: _handleRadius,
                                    ),
                                  ),
                                ),
                                if (_isCropping)
                                  const Positioned.fill(
                                    child: ColoredBox(
                                      color: Colors.black54,
                                      child: Center(
                                        child: CircularProgressIndicator(color: Colors.white),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

/// Dims everything outside the selected 4-sided area, draws its outline
/// and the 4 corner handles.
class _QuadPainter extends CustomPainter {
  final List<Offset> corners;
  final Rect imageRect;
  final int? activeCorner;
  final double handleRadius;

  _QuadPainter({
    required this.corners,
    required this.imageRect,
    required this.activeCorner,
    required this.handleRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (corners.length != 4) return;
    final quad = Path()..addPolygon(corners, true);

    final dim = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(imageRect)
      ..addPath(quad, Offset.zero);
    canvas.drawPath(dim, Paint()..color = Colors.black.withOpacity(0.30));

    canvas.drawPath(
      quad,
      Paint()
        ..color = Colors.lightBlueAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    for (int i = 0; i < 4; i++) {
      final active = i == activeCorner;
      final r = active ? handleRadius + 4 : handleRadius;
      canvas.drawCircle(
        corners[i],
        r,
        Paint()..color = active ? Colors.lightBlueAccent : Colors.white,
      );
      canvas.drawCircle(
        corners[i],
        r,
        Paint()
          ..color = Colors.lightBlueAccent
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _QuadPainter old) =>
      old.corners != corners ||
      old.activeCorner != activeCorner ||
      old.imageRect != imageRect;
}

// ---------------------------------------------------------------------
// Border detection (top-level so it can run in an isolate).
//
// 1. PAPER: starts from the largest bright region, then GROWS through
//    smooth shading (it only stops at sharp edges such as the paper's
//    border or letters). Parts of the page in a shadow are still paper,
//    so letters in a shaded part are no longer left out. A shaded part
//    cut off by a hard shadow line is added too if it has the same tint
//    as the paper.
// 2. TEXT AREA: ink = pixels clearly darker than their OWN surroundings
//    (local brightness), not darker than the white paper. So faint pen
//    and letters in shadow are found too. The box around all the ink,
//    plus a margin, is where the corners start (right under the last
//    line). Letters close to a paper edge snap the border to that edge.
// 3. If no writing is found, the corners start on the paper's 4
//    corners; if no paper either, on the whole image.
// Returns {'width', 'height', 'quad': [[x,y] x4] or null, 'mode'} in
// ORIGINAL image pixels, corners ordered TL, TR, BR, BL.
// mode is 'text', 'paper' or 'none'.
// ---------------------------------------------------------------------
const int _detectWidth = 400;
const double _minPaperAreaFrac = 0.20; // paper must cover >= 20% of the photo
const double _minCandidateAreaFrac = 0.05; // bright regions >= 5% may be the paper
const int _maxPaperCandidates = 3; // check the 3 biggest bright regions
const double _leakFrac = 0.97; // grown to >= 97% of the photo = leaked into the background
const double _fullFrameAreaFrac = 0.97; // >= 97%: paper already fills the photo
const int _solidCheckStep = 3; // ignore thin bright specks / lines
const double _smoothEdgeLimit = 12; // brightness change per pixel that counts as an edge
const double _shadeMinBrightness = 0.40; // shaded paper: >= 40% of the lit paper
const double _shadeTintTolerance = 0.08; // shaded paper: same colour tint as the paper
const double _shadeMinAreaFrac = 0.01; // shaded part must be >= 1% of the photo
const int _shadeTouchPx = 5; // shaded part must touch the paper (within 5 px)
const double _inkLocalFrac = 0.80; // ink = darker than 80% of its surroundings
const int _inkLocalMinDiff = 12; // ... and at least 12 levels darker
const double _edgeWidenFrac = 0.02; // widen the paper area 2%
const double _textMarginLetters = 0.8; // margin around the text, in letter sizes
const double _minTextMarginPx = 6; // (at detection size) never less than this
const double _snapLetters = 1.5; // text this close to the paper edge -> go to the edge

Map<String, dynamic> detectPaperCorners(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return {'width': 1, 'height': 1, 'quad': null, 'mode': 'none'};
  final oriented = img.bakeOrientation(decoded);
  final result = <String, dynamic>{
    'width': oriented.width,
    'height': oriented.height,
    'quad': null,
    'mode': 'none',
  };

  final small = img.copyResize(oriented, width: _detectWidth);
  final w = small.width, h = small.height;
  final n = w * h;
  if (w < 20 || h < 20) return result;
  final scale = oriented.width / w;

  // ---- grayscale (+ colour for the tint check) + Otsu -> bright mask ----
  final gray = List<int>.filled(n, 0);
  final red = List<int>.filled(n, 0), green = List<int>.filled(n, 0), blue = List<int>.filled(n, 0);
  final histogram = List<int>.filled(256, 0);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final p = small.getPixel(x, y);
      final i = y * w + x;
      red[i] = p.r.toInt();
      green[i] = p.g.toInt();
      blue[i] = p.b.toInt();
      final v = (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255);
      gray[i] = v;
      histogram[v]++;
    }
  }
  final threshold = _otsuThreshold(histogram, n);
  bool bright(int x, int y) =>
      x >= 0 && y >= 0 && x < w && y < h && gray[y * w + x] > threshold;

  // "Solid" bright pixels only (removes lone bright specks / thin lines)
  const s = _solidCheckStep;
  final solid = List<bool>.filled(n, false);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      if (!bright(x, y)) continue;
      int c = 0;
      if (bright(x + s, y)) c++;
      if (bright(x - s, y)) c++;
      if (bright(x, y + s)) c++;
      if (bright(x, y - s)) c++;
      solid[y * w + x] = c >= 2;
    }
  }

  // Ink = clearly darker than its own surroundings (local mean), so it
  // works on white paper, in shadow and for faint pen alike. Found on
  // the whole photo first; later only the ink on the paper is used.
  final localMean = _boxMean(gray, w, h, math.max(8, w ~/ 20));
  final inkAll = List<bool>.filled(n, false);
  for (int i = 0; i < n; i++) {
    final m = localMean[i];
    inkAll[i] = gray[i] < _inkLocalFrac * m && m - gray[i] > _inkLocalMinDiff;
  }
  final inkAllLabel = List<int>.filled(n, 0);
  final letterLike = _connectedComponents(inkAll, w, h, inkAllLabel, eightConnected: true)
      .where((c) =>
          c.area >= 3 &&
          math.max(c.width, c.height) >= 3 &&
          c.width < 0.5 * w &&
          c.height < 0.5 * h &&
          c.area < 0.02 * n)
      .toList();

  // ---- 1. PAPER ----
  // Candidates = the biggest bright regions (paper, but maybe also a
  // lit laptop screen, a white wall or a table). Each one is grown
  // through smooth shading; the one with the MOST writing on it is the
  // paper. (Before, the biggest bright region always won, so a bright
  // background sometimes "stole" the paper - that is why it worked
  // only sometimes.)
  final seedLabel = List<int>.filled(n, 0);
  final components = _connectedComponents(solid, w, h, seedLabel, eightConnected: false)
    ..sort((p, q) => q.area.compareTo(p.area));
  final candidates = components
      .where((c) => c.area >= _minCandidateAreaFrac * n)
      .take(_maxPaperCandidates)
      .toList();
  final smooth = _smoothMask(gray, w, h);

  List<bool>? bestPaper;
  int bestInk = -1, bestArea = 0;
  for (final cand in candidates) {
    final grown = _growPaper(cand.id, seedLabel, smooth, gray, red, green, blue, w, h);
    final region = _rowSpanRegion(grown, w, h, 0);
    int inkCount = 0, area = 0;
    for (int i = 0; i < n; i++) {
      if (grown[i]) area++;
    }
    for (final c in letterLike) {
      final cx = (c.minX + c.maxX) ~/ 2, cy = (c.minY + c.maxY) ~/ 2;
      if (region != null && region[cy * w + cx]) inkCount++;
    }
    if (inkCount > bestInk || (inkCount == bestInk && area > bestArea)) {
      bestInk = inkCount;
      bestArea = area;
      bestPaper = grown;
    }
  }
  final hasPaper = bestPaper != null && bestArea / n >= _minPaperAreaFrac;
  final List<bool> paper =
      (hasPaper && bestPaper != null) ? bestPaper : List<bool>.filled(n, true);

  int paperCount = 0;
  for (int i = 0; i < n; i++) {
    if (paper[i]) paperCount++;
  }
  final paperFrac = paperCount / n;

  // Paper's 4 corners (only when a separate sheet is visible).
  // Straight lines are fitted along the paper's 4 sides, so a slanted
  // side gives a slanted border. A side cut off by the photo's edge
  // uses the photo's edge.
  final List<List<double>>? paperSmall = // detection-size pixels
      (hasPaper && paperFrac < _fullFrameAreaFrac)
          ? (_paperSideLines(paper, w, h) ?? _paperExtremeCorners(paper, w, h))
          : null;
  final List<List<double>>? paperQuad = paperSmall == null
      ? null
      : [for (final p in paperSmall) [p[0] * scale, p[1] * scale]];

  // ---- 2. TEXT AREA ----
  // Where to look: the paper's row spans (holes such as letters filled
  // in), widened a little.
  final inside = _rowSpanRegion(paper, w, h, math.max(2, (_edgeWidenFrac * w).round()));
  if (inside == null) return _fallback(result, paperQuad);
  final ink = List<bool>.filled(n, false);
  for (int i = 0; i < n; i++) {
    ink[i] = inside[i] && inkAll[i];
  }

  // Ink pieces; drop specks and anything too big to be writing
  // (table / shadow strips hugging the edge, notebook lines)
  final inkLabel = List<int>.filled(n, 0);
  final pieces = _connectedComponents(ink, w, h, inkLabel, eightConnected: true)
      .where((c) =>
          c.area >= 3 &&
          c.width < 0.5 * w &&
          c.height < 0.5 * h &&
          c.area < 0.02 * n)
      .toList();
  if (pieces.isEmpty) return _fallback(result, paperQuad);

  final sizes = pieces.map((c) => math.max(c.width, c.height).toDouble()).toList()..sort();
  final letterSize = sizes[((sizes.length - 1) * 0.9).round()];
  final significant = pieces.where((c) => math.max(c.width, c.height) >= 0.4 * letterSize);
  final margin = math.max(_minTextMarginPx, _textMarginLetters * letterSize);

  if (paperSmall != null) {
    // ---- Separate sheet visible: box lines up with the paper ----
    // Every ink pixel is expressed as (u, v) inside the paper
    // (0..1 across, 0..1 down), the box is taken there and mapped back,
    // so its sides are parallel to the paper's sides (slanted if the
    // paper is slanted).
    final _Homography? toPaperOrNull = _Homography.quadToSquare(paperSmall);
    final _Homography? toImageOrNull = _Homography.squareToQuad(paperSmall);
    if (toPaperOrNull != null && toImageOrNull != null) {
      final _Homography toPaper = toPaperOrNull;
      final _Homography toImage = toImageOrNull;
      final List<List<double>> sheet = paperSmall;
      final sigIds = {for (final c in significant) c.id};
      double u0 = double.infinity, v0 = double.infinity;
      double u1 = -double.infinity, v1 = -double.infinity;
      for (int i = 0; i < n; i++) {
        if (!ink[i] || !sigIds.contains(inkLabel[i])) continue;
        final uv = toPaper.map(i % w + 0.5, i ~/ w + 0.5);
        if (uv[0] < u0) u0 = uv[0];
        if (uv[0] > u1) u1 = uv[0];
        if (uv[1] < v0) v0 = uv[1];
        if (uv[1] > v1) v1 = uv[1];
      }
      double dist(List<double> p, List<double> q) {
        final dx = p[0] - q[0], dy = p[1] - q[1];
        return math.sqrt(dx * dx + dy * dy);
      }
      final double paperW = (dist(sheet[0], sheet[1]) + dist(sheet[3], sheet[2])) / 2;
      final double paperH = (dist(sheet[0], sheet[3]) + dist(sheet[1], sheet[2])) / 2;
      if (u1 > u0 && v1 > v0 && paperW > 1 && paperH > 1) {
        u0 -= margin / paperW;
        u1 += margin / paperW;
        v0 -= margin / paperH;
        v1 += margin / paperH;
        // Text close to a paper edge -> border goes to that edge
        final snapU = _snapLetters * letterSize / paperW;
        final snapV = _snapLetters * letterSize / paperH;
        if (u0 < snapU) u0 = 0.0;
        if (v0 < snapV) v0 = 0.0;
        if (u1 > 1 - snapU) u1 = 1.0;
        if (v1 > 1 - snapV) v1 = 1.0;
        u0 = math.max(0.0, u0);
        v0 = math.max(0.0, v0);
        u1 = math.min(1.0, u1);
        v1 = math.min(1.0, v1);

        List<double> back(double u, double v) {
          final p = toImage.map(u, v);
          return [
            math.min(math.max(p[0], 0.0), w.toDouble()) * scale,
            math.min(math.max(p[1], 0.0), h.toDouble()) * scale,
          ];
        }

        result['quad'] = [back(u0, v0), back(u1, v0), back(u1, v1), back(u0, v1)];
        result['mode'] = 'text';
        return result;
      }
    }
  }

  // ---- Paper fills the photo: straight box tight around the writing ----
  double x0 = significant.map((c) => c.minX).reduce(math.min) - margin;
  double y0 = significant.map((c) => c.minY).reduce(math.min) - margin;
  double x1 = significant.map((c) => c.maxX + 1).reduce(math.max) + margin;
  double y1 = significant.map((c) => c.maxY + 1).reduce(math.max) + margin;
  x0 = math.max(0, x0);
  y0 = math.max(0, y0);
  x1 = math.min(w.toDouble(), x1);
  y1 = math.min(h.toDouble(), y1);
  if (x1 - x0 < 10 || y1 - y0 < 10) return _fallback(result, paperQuad);

  result['quad'] = [
    [x0 * scale, y0 * scale],
    [x1 * scale, y0 * scale],
    [x1 * scale, y1 * scale],
    [x0 * scale, y1 * scale],
  ];
  result['mode'] = 'text';
  return result;
}

Map<String, dynamic> _fallback(Map<String, dynamic> result, List<List<double>>? paperQuad) {
  if (paperQuad != null) {
    result['quad'] = paperQuad;
    result['mode'] = 'paper';
  }
  return result;
}

/// true where the brightness changes slowly (no edge): 3x3 blur, then
/// the largest per-pixel change (Sobel / 8) must be below the limit.
List<bool> _smoothMask(List<int> gray, int w, int h) {
  final blur = _boxMean(gray, w, h, 1);
  double at(int x, int y) {
    final cx = x < 0 ? 0 : (x >= w ? w - 1 : x);
    final cy = y < 0 ? 0 : (y >= h ? h - 1 : y);
    return blur[cy * w + cx];
  }

  final smooth = List<bool>.filled(w * h, false);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final gx = (at(x + 1, y - 1) + 2 * at(x + 1, y) + at(x + 1, y + 1)) -
          (at(x - 1, y - 1) + 2 * at(x - 1, y) + at(x - 1, y + 1));
      final gy = (at(x - 1, y + 1) + 2 * at(x, y + 1) + at(x + 1, y + 1)) -
          (at(x - 1, y - 1) + 2 * at(x, y - 1) + at(x + 1, y - 1));
      smooth[y * w + x] = math.max(gx.abs(), gy.abs()) / 8 < _smoothEdgeLimit;
    }
  }
  return smooth;
}

/// Mean of the (2r+1)x(2r+1) window around every pixel (integral image).
List<double> _boxMean(List<int> gray, int w, int h, int r) {
  final sw = w + 1;
  final sum = List<int>.filled(sw * (h + 1), 0);
  for (int y = 0; y < h; y++) {
    int row = 0;
    for (int x = 0; x < w; x++) {
      row += gray[y * w + x];
      sum[(y + 1) * sw + x + 1] = sum[y * sw + x + 1] + row;
    }
  }
  final out = List<double>.filled(w * h, 0);
  for (int y = 0; y < h; y++) {
    final ya = math.max(0, y - r), yb = math.min(h, y + r + 1);
    for (int x = 0; x < w; x++) {
      final xa = math.max(0, x - r), xb = math.min(w, x + r + 1);
      final total = sum[yb * sw + xb] - sum[ya * sw + xb] - sum[yb * sw + xa] + sum[ya * sw + xa];
      out[y * w + x] = total / ((yb - ya) * (xb - xa));
    }
  }
  return out;
}

/// Adds smooth regions next to the paper that look like the same paper
/// in shadow: big enough, not too dark, same colour tint.
void _addShadedParts(
  List<bool> paper,
  List<bool> smooth,
  List<int> gray,
  List<int> red,
  List<int> green,
  List<int> blue,
  int w,
  int h,
) {
  final n = w * h;

  // paper brightness (median) and tint (mean R/G, B/G)
  final hist = List<int>.filled(256, 0);
  int count = 0;
  double rg = 0, bg = 0;
  for (int i = 0; i < n; i++) {
    if (!paper[i]) continue;
    hist[gray[i]]++;
    count++;
    rg += (red[i] + 1) / (green[i] + 1);
    bg += (blue[i] + 1) / (green[i] + 1);
  }
  if (count == 0) return;
  final paperMedian = _histMedian(hist, count);
  final paperRg = rg / count, paperBg = bg / count;

  // "near the paper" = paper grown by a few pixels (separable max)
  final t = _shadeTouchPx;
  final nearRow = List<bool>.filled(n, false);
  for (int y = 0; y < h; y++) {
    int last = -100000;
    for (int x = 0; x < w; x++) {
      if (paper[y * w + x]) last = x;
      if (x - last <= t) nearRow[y * w + x] = true;
    }
    last = 100000;
    for (int x = w - 1; x >= 0; x--) {
      if (paper[y * w + x]) last = x;
      if (last - x <= t) nearRow[y * w + x] = true;
    }
  }
  final near = List<bool>.filled(n, false);
  for (int x = 0; x < w; x++) {
    int last = -100000;
    for (int y = 0; y < h; y++) {
      if (nearRow[y * w + x]) last = y;
      if (y - last <= t) near[y * w + x] = true;
    }
    last = 100000;
    for (int y = h - 1; y >= 0; y--) {
      if (nearRow[y * w + x]) last = y;
      if (last - y <= t) near[y * w + x] = true;
    }
  }

  final candidate = List<bool>.generate(n, (i) => smooth[i] && !paper[i]);
  final labels = List<int>.filled(n, 0);
  final comps = _connectedComponents(candidate, w, h, labels, eightConnected: false);
  final keep = <int>{};
  final minArea = _shadeMinAreaFrac * n;
  final big = {for (final c in comps) if (c.area >= minArea) c.id: c};
  if (big.isEmpty) return;

  final touches = <int>{};
  final cHist = {for (final id in big.keys) id: List<int>.filled(256, 0)};
  final cRg = {for (final id in big.keys) id: 0.0};
  final cBg = {for (final id in big.keys) id: 0.0};
  for (int i = 0; i < n; i++) {
    final id = labels[i];
    if (!big.containsKey(id)) continue;
    if (near[i]) touches.add(id);
    cHist[id]![gray[i]]++;
    cRg[id] = cRg[id]! + (red[i] + 1) / (green[i] + 1);
    cBg[id] = cBg[id]! + (blue[i] + 1) / (green[i] + 1);
  }
  for (final entry in big.entries) {
    final id = entry.key, area = entry.value.area;
    if (!touches.contains(id)) continue;
    if (_histMedian(cHist[id]!, area) < _shadeMinBrightness * paperMedian) continue;
    if ((cRg[id]! / area - paperRg).abs() > _shadeTintTolerance) continue;
    if ((cBg[id]! / area - paperBg).abs() > _shadeTintTolerance) continue;
    keep.add(id);
  }
  if (keep.isEmpty) return;
  for (int i = 0; i < n; i++) {
    if (keep.contains(labels[i])) paper[i] = true;
  }
}

int _histMedian(List<int> hist, int count) {
  int acc = 0;
  for (int v = 0; v < 256; v++) {
    acc += hist[v];
    if (acc >= count / 2) return v;
  }
  return 255;
}

/// Grows one bright region through smooth shading, then adds shaded
/// parts cut off by a hard shadow line. If the growing "leaks" into the
/// whole background (fills the photo), it goes back to the bright
/// region alone.
List<bool> _growPaper(
  int seedId,
  List<int> seedLabel,
  List<bool> smooth,
  List<int> gray,
  List<int> red,
  List<int> green,
  List<int> blue,
  int w,
  int h,
) {
  final n = w * h;
  final paper = List<bool>.filled(n, false);
  final queue = List<int>.filled(n, 0);
  int head = 0, tail = 0, seedArea = 0;
  for (int i = 0; i < n; i++) {
    if (seedLabel[i] != seedId) continue;
    seedArea++;
    if (smooth[i]) {
      paper[i] = true;
      queue[tail++] = i;
    }
  }
  while (head < tail) {
    final i = queue[head++];
    final x = i % w, y = i ~/ w;
    if (x > 0) tail = _visit(i - 1, paper, smooth, queue, tail);
    if (x < w - 1) tail = _visit(i + 1, paper, smooth, queue, tail);
    if (y > 0) tail = _visit(i - w, paper, smooth, queue, tail);
    if (y < h - 1) tail = _visit(i + w, paper, smooth, queue, tail);
  }
  final leaked = tail >= _leakFrac * n && seedArea < 0.9 * n;
  if (tail == 0 || leaked) {
    for (int i = 0; i < n; i++) {
      paper[i] = seedLabel[i] == seedId;
    }
    return paper;
  }
  _addShadedParts(paper, smooth, gray, red, green, blue, w, h);
  return paper;
}

int _visit(int j, List<bool> paper, List<bool> smooth, List<int> queue, int tail) {
  if (!paper[j] && smooth[j]) {
    paper[j] = true;
    queue[tail++] = j;
  }
  return tail;
}

/// Fills each row of `mask` from its first to its last pixel (so holes
/// such as letters are included), widened by `d` pixels. null if empty.
List<bool>? _rowSpanRegion(List<bool> mask, int w, int h, int d) {
  int firstRow = -1, lastRow = -1;
  final rowStart = List<int>.filled(h, -1), rowEnd = List<int>.filled(h, -1);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      if (!mask[y * w + x]) continue;
      if (rowStart[y] < 0) rowStart[y] = x;
      rowEnd[y] = x;
    }
    if (rowStart[y] >= 0) {
      if (firstRow < 0) firstRow = y;
      lastRow = y;
    }
  }
  if (firstRow < 0) return null;
  final out = List<bool>.filled(w * h, false);
  for (int y = math.max(0, firstRow - d); y < math.min(h, lastRow + 1 + d); y++) {
    final src = y < firstRow ? firstRow : (y > lastRow ? lastRow : y);
    if (rowStart[src] < 0) continue;
    final a = math.max(0, rowStart[src] - d), b = math.min(w, rowEnd[src] + 1 + d);
    for (int x = a; x < b; x++) {
      out[y * w + x] = true;
    }
  }
  return out;
}

/// Fits a straight line along each of the paper's 4 sides and returns
/// their 4 crossing points [TL, TR, BR, BL], or null if the result looks
/// wrong. A side that lies on the photo's edge (paper cut off) is the
/// photo's edge.
List<List<double>>? _paperSideLines(List<bool> paper, int w, int h) {
  // Top / bottom: for each column, first / last paper row.
  // Left / right: for each row, first / last paper column.
  final topPts = <List<double>>[], botPts = <List<double>>[];
  final leftPts = <List<double>>[], rightPts = <List<double>>[];
  int cols = 0, rows = 0;
  for (int x = 0; x < w; x++) {
    int first = -1, last = -1;
    for (int y = 0; y < h; y++) {
      if (paper[y * w + x]) {
        if (first < 0) first = y;
        last = y;
      }
    }
    if (first < 0) continue;
    cols++;
    if (first > 0) topPts.add([x.toDouble(), first.toDouble()]);
    if (last < h - 1) botPts.add([x.toDouble(), last + 1.0]);
  }
  for (int y = 0; y < h; y++) {
    int first = -1, last = -1;
    for (int x = 0; x < w; x++) {
      if (paper[y * w + x]) {
        if (first < 0) first = x;
        last = x;
      }
    }
    if (first < 0) continue;
    rows++;
    if (first > 0) leftPts.add([y.toDouble(), first.toDouble()]);
    if (last < w - 1) rightPts.add([y.toDouble(), last + 1.0]);
  }
  if (cols == 0 || rows == 0) return null;

  // y = a*x + b for top/bottom, x = a*y + b for left/right
  final top = topPts.length >= 0.3 * cols ? _fitLine(topPts) : null;
  final bot = botPts.length >= 0.3 * cols ? _fitLine(botPts) : null;
  final left = leftPts.length >= 0.3 * rows ? _fitLine(leftPts) : null;
  final right = rightPts.length >= 0.3 * rows ? _fitLine(rightPts) : null;
  final t = top ?? [0.0, 0.0];
  final bo = bot ?? [0.0, h.toDouble()];
  final l = left ?? [0.0, 0.0];
  final r = right ?? [0.0, w.toDouble()];

  List<double>? cross(List<double> hl, List<double> vl) {
    final den = 1 - hl[0] * vl[0];
    if (den.abs() < 1e-6) return null;
    final y = (hl[0] * vl[1] + hl[1]) / den;
    return [vl[0] * y + vl[1], y];
  }

  final tl = cross(t, l), tr = cross(t, r), br = cross(bo, r), bl = cross(bo, l);
  if (tl == null || tr == null || br == null || bl == null) return null;
  final quad = [tl, tr, br, bl];

  // sanity: convex, corners not far outside the photo, big enough
  double sign = 0;
  for (int i = 0; i < 4; i++) {
    final p = quad[i], q = quad[(i + 1) % 4], o = quad[(i + 2) % 4];
    final c = (q[0] - p[0]) * (o[1] - q[1]) - (q[1] - p[1]) * (o[0] - q[0]);
    if (c.abs() < 1e-9) return null;
    if (sign == 0) sign = c.sign;
    if (c.sign != sign) return null;
  }
  for (final p in quad) {
    if (p[0] < -0.1 * w || p[0] > 1.1 * w || p[1] < -0.1 * h || p[1] > 1.1 * h) return null;
  }
  double area = 0;
  for (int i = 0; i < 4; i++) {
    final p = quad[i], q = quad[(i + 1) % 4];
    area += p[0] * q[1] - q[0] * p[1];
  }
  if (area.abs() / 2 < _minPaperAreaFrac * w * h) return null;
  return quad;
}

/// Least-squares line s = a*t + b through points [t, s], refitted
/// without the points that are far off (e.g. a torn / shaded bit).
List<double>? _fitLine(List<List<double>> pts) {
  var p = pts;
  List<double>? line;
  for (int round = 0; round < 3; round++) {
    if (p.length < 2) return line;
    double st = 0, ss = 0, stt = 0, sts = 0;
    for (final q in p) {
      st += q[0];
      ss += q[1];
      stt += q[0] * q[0];
      sts += q[0] * q[1];
    }
    final m = p.length.toDouble();
    final den = m * stt - st * st;
    if (den.abs() < 1e-9) return line;
    final a = (m * sts - st * ss) / den;
    final b = (ss - a * st) / m;
    line = [a, b];
    final res = [for (final q in p) (q[1] - (a * q[0] + b)).abs()]..sort();
    final limit = math.max(2.0, res[((res.length - 1) * 0.8).round()]);
    final kept = [for (final q in p) if ((q[1] - (a * q[0] + b)).abs() <= limit) q];
    if (kept.length == p.length) break;
    p = kept;
  }
  return line;
}

/// Old method: the paper pixels furthest toward each corner.
List<List<double>>? _paperExtremeCorners(List<bool> paper, int w, int h) {
  double bestTl = double.infinity, bestBr = -double.infinity;
  double bestTr = -double.infinity, bestBl = -double.infinity;
  List<double>? tl, tr, br, bl;
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      if (!paper[y * w + x]) continue;
      final sum = (x + y).toDouble(), diff = (x - y).toDouble();
      if (sum < bestTl) { bestTl = sum; tl = [x.toDouble(), y.toDouble()]; }
      if (sum > bestBr) { bestBr = sum; br = [x.toDouble(), y.toDouble()]; }
      if (diff > bestTr) { bestTr = diff; tr = [x.toDouble(), y.toDouble()]; }
      if (-diff > bestBl) { bestBl = -diff; bl = [x.toDouble(), y.toDouble()]; }
    }
  }
  if (tl == null || tr == null || br == null || bl == null) return null;
  return [tl, tr, br, bl];
}

/// 3x3 perspective mapping between the unit square and a 4-sided shape.
class _Homography {
  final List<double> m; // row-major 3x3
  _Homography(this.m);

  List<double> map(double x, double y) {
    final z = m[6] * x + m[7] * y + m[8];
    return [(m[0] * x + m[1] * y + m[2]) / z, (m[3] * x + m[4] * y + m[5]) / z];
  }

  /// (0,0),(1,0),(1,1),(0,1) -> quad [TL, TR, BR, BL]
  static _Homography? squareToQuad(List<List<double>> q) {
    final x0 = q[0][0], y0 = q[0][1], x1 = q[1][0], y1 = q[1][1];
    final x2 = q[2][0], y2 = q[2][1], x3 = q[3][0], y3 = q[3][1];
    final dx1 = x1 - x2, dx2 = x3 - x2, dx3 = x0 - x1 + x2 - x3;
    final dy1 = y1 - y2, dy2 = y3 - y2, dy3 = y0 - y1 + y2 - y3;
    double g = 0, hh = 0;
    if (dx3.abs() > 1e-9 || dy3.abs() > 1e-9) {
      final det = dx1 * dy2 - dx2 * dy1;
      if (det.abs() < 1e-12) return null;
      g = (dx3 * dy2 - dx2 * dy3) / det;
      hh = (dx1 * dy3 - dx3 * dy1) / det;
    }
    return _Homography([
      x1 - x0 + g * x1, x3 - x0 + hh * x3, x0,
      y1 - y0 + g * y1, y3 - y0 + hh * y3, y0,
      g, hh, 1,
    ]);
  }

  /// quad [TL, TR, BR, BL] -> unit square
  static _Homography? quadToSquare(List<List<double>> q) {
    final f = squareToQuad(q);
    if (f == null) return null;
    final a = f.m;
    final c00 = a[4] * a[8] - a[5] * a[7];
    final c01 = a[5] * a[6] - a[3] * a[8];
    final c02 = a[3] * a[7] - a[4] * a[6];
    final det = a[0] * c00 + a[1] * c01 + a[2] * c02;
    if (det.abs() < 1e-12) return null;
    return _Homography([
      c00 / det, (a[2] * a[7] - a[1] * a[8]) / det, (a[1] * a[5] - a[2] * a[4]) / det,
      c01 / det, (a[0] * a[8] - a[2] * a[6]) / det, (a[2] * a[3] - a[0] * a[5]) / det,
      c02 / det, (a[1] * a[6] - a[0] * a[7]) / det, (a[0] * a[4] - a[1] * a[3]) / det,
    ]);
  }
}

class _Component {
  final int id;
  int area = 0;
  int minX, minY, maxX = 0, maxY = 0;
  _Component(this.id, this.minX, this.minY);
  int get width => maxX - minX + 1;
  int get height => maxY - minY + 1;
}

/// Labels connected regions of `mask` (BFS). `labels` is filled in place.
List<_Component> _connectedComponents(
  List<bool> mask,
  int w,
  int h,
  List<int> labels, {
  required bool eightConnected,
}) {
  final result = <_Component>[];
  final queue = List<int>.filled(w * h, 0);
  int current = 0;
  for (int start = 0; start < w * h; start++) {
    if (!mask[start] || labels[start] != 0) continue;
    current++;
    final comp = _Component(current, start % w, start ~/ w);
    int head = 0, tail = 0;
    queue[tail++] = start;
    labels[start] = current;
    while (head < tail) {
      final idx = queue[head++];
      final x = idx % w, y = idx ~/ w;
      comp.area++;
      if (x < comp.minX) comp.minX = x;
      if (x > comp.maxX) comp.maxX = x;
      if (y < comp.minY) comp.minY = y;
      if (y > comp.maxY) comp.maxY = y;
      for (int dy = -1; dy <= 1; dy++) {
        for (int dx = -1; dx <= 1; dx++) {
          if (dx == 0 && dy == 0) continue;
          if (!eightConnected && dx != 0 && dy != 0) continue;
          final nx = x + dx, ny = y + dy;
          if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
          final n = ny * w + nx;
          if (mask[n] && labels[n] == 0) {
            labels[n] = current;
            queue[tail++] = n;
          }
        }
      }
    }
    result.add(comp);
  }
  return result;
}

/// Largest side (px) of the cropped image. The recognizer on the phone
/// shrinks every photo to this size anyway (MAX_IMAGE_SIDE in
/// baybayin_offline.py), so a bigger crop only costs memory: a full
/// 12-megapixel photo straightened at full size needs ~150-200 MB here,
/// on top of the recognizer, which made the app crash when the crop box
/// was left at (almost) the whole photo.
const int kMaxCropOutputSide = 2400;

/// Straightens the selected 4-sided area into a flat rectangle.
/// args: {'bytes': Uint8List, 'quad': [[x,y] x4] in order TL, TR, BR, BL}
Uint8List? rectifyQuad(Map<String, dynamic> args) {
  final decoded = img.decodeImage(args['bytes'] as Uint8List);
  if (decoded == null) return null;
  img.Image source = img.bakeOrientation(decoded);
  var q = [
    for (final p in (args['quad'] as List))
      [(p[0] as num).toDouble(), (p[1] as num).toDouble()]
  ];

  double dist(List<double> a, List<double> b) =>
      math.sqrt(math.pow(a[0] - b[0], 2) + math.pow(a[1] - b[1], 2));

  var outW = math.max(dist(q[0], q[1]), dist(q[3], q[2]));
  var outH = math.max(dist(q[0], q[3]), dist(q[1], q[2]));
  if (outW < 20 || outH < 20) return null;

  // Too big: shrink the whole photo FIRST (averaging, so thin pen strokes
  // are kept, not skipped), then straighten the smaller copy.
  final scale = math.min(1.0, kMaxCropOutputSide / math.max(outW, outH));
  if (scale < 1.0) {
    source = img.copyResize(
      source,
      width: math.max(1, (source.width * scale).round()),
      height: math.max(1, (source.height * scale).round()),
      interpolation: img.Interpolation.average,
    );
    q = [for (final p in q) [p[0] * scale, p[1] * scale]];
    outW *= scale;
    outH *= scale;
  }

  final flat = img.copyRectify(
    source,
    topLeft: img.Point(q[0][0], q[0][1]),
    topRight: img.Point(q[1][0], q[1][1]),
    bottomLeft: img.Point(q[3][0], q[3][1]),
    bottomRight: img.Point(q[2][0], q[2][1]),
    interpolation: img.Interpolation.linear,
    toImage: img.Image(width: outW.round(), height: outH.round()),
  );
  return Uint8List.fromList(img.encodeJpg(flat, quality: 95));
}

int _otsuThreshold(List<int> histogram, int total) {
  double sumAll = 0;
  for (int i = 0; i < 256; i++) {
    sumAll += i * histogram[i];
  }
  double sumBackground = 0;
  int weightBackground = 0;
  double bestVariance = -1;
  int best = 127;
  for (int t = 0; t < 256; t++) {
    weightBackground += histogram[t];
    if (weightBackground == 0) continue;
    final weightForeground = total - weightBackground;
    if (weightForeground == 0) break;
    sumBackground += t * histogram[t];
    final meanBackground = sumBackground / weightBackground;
    final meanForeground = (sumAll - sumBackground) / weightForeground;
    final diff = meanBackground - meanForeground;
    final variance = weightBackground * weightForeground * diff * diff;
    if (variance > bestVariance) {
      bestVariance = variance;
      best = t;
    }
  }
  return best;
}