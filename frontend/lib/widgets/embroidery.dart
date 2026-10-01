import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'dayaw_style.dart';

/// Embroidery look, inspired by Philippine hand embroidery (Lumban calado,
/// piña cloth): linen fabric, running-stitch borders and cross-stitch
/// bands. Everything is drawn with flat thread colors - no gradients.
class Thread {
  Thread._();

  /// Dark brown thread - borders on light fabric.
  static const Color brown = Color(0xFF6D4C41);

  /// Honey thread - accents, bands, the scanner hoop.
  static const Color amber = DayawColors.amber;

  /// Pale thread - stitches on dark fabric.
  static const Color light = Color(0xFFF3E3B3);

  /// Red thread - the classic accent of Filipino cross-stitch.
  static const Color red = Color(0xFFA8473C);

  /// A thread that shows up on [fabric]: dark on light cloth, pale on dark.
  static Color on(Color fabric) =>
      fabric.computeLuminance() > 0.4 ? brown : light;
}

/// Running stitch (- - - -) along a rounded rectangle, drawn [inset]
/// inside the edge like a hand-sewn hem. Each stitch gets a faint shadow
/// on one side so it reads as raised thread, not a dashed line.
class StitchBorderPainter extends CustomPainter {
  final Color color;
  final double radius;
  final double inset;
  final double stitch;
  final double gap;
  final double width;

  const StitchBorderPainter({
    required this.color,
    this.radius = 20,
    this.inset = 6,
    this.stitch = 7,
    this.gap = 4.5,
    this.width = 1.6,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(inset);
    if (rect.width <= 0 || rect.height <= 0) return;
    final r = math.max(0.0, radius - inset);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)));
    _stitchAlong(canvas, path, color, stitch, gap, width);
  }

  @override
  bool shouldRepaint(StitchBorderPainter old) =>
      old.color != color ||
      old.radius != radius ||
      old.inset != inset ||
      old.stitch != stitch ||
      old.gap != gap ||
      old.width != width;
}

/// Draws [path] as a run of thread stitches.
void _stitchAlong(
  Canvas canvas,
  Path path,
  Color color,
  double stitch,
  double gap,
  double width,
) {
  final shadow = Paint()
    ..color = Colors.black.withValues(alpha: 0.18)
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke;
  final thread = Paint()
    ..color = color
    ..strokeWidth = width
    ..strokeCap = StrokeCap.round
    ..style = PaintingStyle.stroke;
  for (final metric in path.computeMetrics()) {
    // Spread the stitches so the run closes evenly on itself.
    final count = math.max(1, (metric.length / (stitch + gap)).floor());
    final step = metric.length / count;
    final length = step * stitch / (stitch + gap);
    for (var i = 0; i < count; i++) {
      final piece = metric.extractPath(i * step, i * step + length);
      canvas.drawPath(piece.shift(const Offset(0.6, 0.9)), shadow);
      canvas.drawPath(piece, thread);
    }
  }
}

/// A straight run of stitches filling its width - for dividers and
/// section-title "threads".
class StitchLine extends StatelessWidget {
  final Color color;
  final double width;
  const StitchLine({super.key, this.color = Thread.amber, this.width = 1.6});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 4,
    child: CustomPaint(painter: _StitchLinePainter(color, width)),
  );
}

class _StitchLinePainter extends CustomPainter {
  final Color color;
  final double width;
  _StitchLinePainter(this.color, this.width);

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final path = Path()
      ..moveTo(width, y)
      ..lineTo(size.width - width, y);
    _stitchAlong(canvas, path, color, 6, 4, width);
  }

  @override
  bool shouldRepaint(_StitchLinePainter old) =>
      old.color != color || old.width != width;
}

/// A cross-stitch band: a row of X stitches with a small diamond motif
/// repeating along it, like the border of an embroidered cloth.
class CrossStitchBand extends StatelessWidget {
  final double height;
  const CrossStitchBand({super.key, this.height = 14});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: double.infinity,
    child: const CustomPaint(painter: _CrossStitchPainter()),
  );
}

class _CrossStitchPainter extends CustomPainter {
  const _CrossStitchPainter();

  // One motif, 7 cells wide x 3 tall: 1 = amber X, 2 = red X, 0 = empty.
  static const _motif = [
    [0, 0, 0, 2, 0, 0, 0],
    [1, 0, 2, 1, 2, 0, 1],
    [0, 0, 0, 2, 0, 0, 0],
  ];

  @override
  void paint(Canvas canvas, Size size) {
    final cell = size.height / _motif.length;
    final amber = Paint()
      ..color = Thread.amber
      ..strokeWidth = math.max(1.0, cell * 0.28)
      ..strokeCap = StrokeCap.round;
    final red = Paint()
      ..color = Thread.red
      ..strokeWidth = amber.strokeWidth
      ..strokeCap = StrokeCap.round;
    final columns = (size.width / cell).floor();
    final pad = cell * 0.2;
    for (var col = 0; col < columns; col++) {
      for (var row = 0; row < _motif.length; row++) {
        final kind = _motif[row][col % _motif[row].length];
        if (kind == 0) continue;
        final r = Rect.fromLTWH(
          col * cell,
          row * cell,
          cell,
          cell,
        ).deflate(pad);
        final paint = kind == 1 ? amber : red;
        canvas.drawLine(r.topLeft, r.bottomRight, paint);
        canvas.drawLine(r.bottomLeft, r.topRight, paint);
      }
    }
  }

  @override
  bool shouldRepaint(_CrossStitchPainter old) => false;
}

/// Linen: the flat [color] with a fine woven texture of horizontal and
/// vertical threads, plus a few irregular slubs like real cloth. Drawn
/// once and cached (it never changes).
class LinenBackground extends StatelessWidget {
  final Color color;
  final Widget child;
  const LinenBackground({super.key, required this.color, required this.child});

  @override
  Widget build(BuildContext context) => Stack(
    children: [
      Positioned.fill(
        child: RepaintBoundary(
          child: CustomPaint(painter: _LinenPainter(color)),
        ),
      ),
      Positioned.fill(child: child),
    ],
  );
}

class _LinenPainter extends CustomPainter {
  final Color color;
  _LinenPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = color);
    final warp = Paint()
      ..color = const Color(0xFF6D4C41).withValues(alpha: 0.045)
      ..strokeWidth = 1;
    final weft = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    final points = <Offset>[];
    for (var y = 0.0; y < size.height; y += 3) {
      points
        ..add(Offset(0, y))
        ..add(Offset(size.width, y));
    }
    canvas.drawPoints(ui.PointMode.lines, points, warp);
    points.clear();
    for (var x = 1.5; x < size.width; x += 3) {
      points
        ..add(Offset(x, 0))
        ..add(Offset(x, size.height));
    }
    canvas.drawPoints(ui.PointMode.lines, points, weft);

    // Slubs: short thicker bits in the weave, placed the same every time.
    final random = math.Random(11);
    final slub = Paint()
      ..color = const Color(0xFF6D4C41).withValues(alpha: 0.06)
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    final count = (size.width * size.height / 2600).round();
    for (var i = 0; i < count; i++) {
      final x = random.nextDouble() * size.width;
      final y = (random.nextDouble() * size.height / 3).floor() * 3.0;
      final length = 4 + random.nextDouble() * 12;
      canvas.drawLine(Offset(x, y), Offset(x + length, y), slub);
    }
  }

  @override
  bool shouldRepaint(_LinenPainter old) => old.color != color;
}
