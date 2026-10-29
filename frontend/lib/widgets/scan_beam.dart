import 'package:flutter/material.dart';

import 'dayaw_style.dart';

/// The scanner's motion: a beam that glides down and back up, easing at
/// each end, with a soft glow trailing behind it. Optional viewfinder
/// corners frame the area. [animation] is a repeating 0..1 loop (one
/// down-and-up sweep per loop). [strong] brightens it while a photo is
/// being read.
class ScanBeam extends StatelessWidget {
  final Animation<double> animation;
  final bool strong;
  final bool corners;

  const ScanBeam({
    super.key,
    required this.animation,
    this.strong = false,
    this.corners = true,
  });

  @override
  Widget build(BuildContext context) {
    final color = DayawColors.sun;
    final corner = DayawColors.amber;
    CustomPaint paintAt(double value) => CustomPaint(
      size: Size.infinite,
      painter: _ScanBeamPainter(
        value: value,
        color: color,
        cornerColor: corner,
        strong: strong,
        corners: corners,
      ),
    );
    return IgnorePointer(
      child: RepaintBoundary(
        child: AnimatedBuilder(
          animation: animation,
          builder: (context, _) => paintAt(animation.value),
        ),
      ),
    );
  }
}

class _ScanBeamPainter extends CustomPainter {
  final double value;
  final Color color;
  final Color cornerColor;
  final bool strong;
  final bool corners;

  _ScanBeamPainter({
    required this.value,
    required this.color,
    required this.cornerColor,
    required this.strong,
    required this.corners,
  });

  static const _inset = 18.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    if (corners) _paintCorners(canvas, size);

    // Ping-pong 0..1..0 with a gentle ease at both ends.
    final goingDown = value < 0.5;
    final phase = goingDown ? value * 2 : 2 - value * 2;
    final t = Curves.easeInOutSine.transform(phase);
    final top = _inset + 6;
    final bottom = size.height - _inset - 6;
    final y = top + (bottom - top) * t;
    final left = _inset + 4;
    final right = size.width - _inset - 4;

    // Trail: a soft wash behind the beam, fading away from it.
    const trail = 64.0;
    final trailRect = goingDown
        ? Rect.fromLTRB(left, y - trail, right, y)
        : Rect.fromLTRB(left, y, right, y + trail);
    canvas.drawRect(
      trailRect,
      Paint()
        ..shader = LinearGradient(
          begin: goingDown ? Alignment.topCenter : Alignment.bottomCenter,
          end: goingDown ? Alignment.bottomCenter : Alignment.topCenter,
          colors: [
            color.withValues(alpha: 0),
            color.withValues(alpha: strong ? 0.30 : 0.16),
          ],
        ).createShader(trailRect),
    );

    // Beam: a bright line fading out at both ends, over a blurred glow.
    final beam = Rect.fromLTRB(left, y - 1, right, y + 1);
    final fade = LinearGradient(
      colors: [
        color.withValues(alpha: 0),
        color,
        color,
        color.withValues(alpha: 0),
      ],
      stops: const [0, 0.15, 0.85, 1],
    ).createShader(beam);
    canvas.drawRect(
      beam.inflate(3),
      Paint()
        ..shader = fade
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, strong ? 7 : 5),
    );
    canvas.drawRect(beam, Paint()..shader = fade);
  }

  void _paintCorners(Canvas canvas, Size size) {
    const arm = 22.0;
    const r = 8.0;
    final paint = Paint()
      ..color = cornerColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    final l = _inset, t = _inset;
    final rr = size.width - _inset, b = size.height - _inset;
    // Each corner: an arm, a rounded bend, another arm.
    canvas.drawPath(
      Path()
        ..moveTo(l, t + arm)
        ..lineTo(l, t + r)
        ..arcToPoint(Offset(l + r, t), radius: const Radius.circular(r))
        ..lineTo(l + arm, t)
        ..moveTo(rr - arm, t)
        ..lineTo(rr - r, t)
        ..arcToPoint(Offset(rr, t + r), radius: const Radius.circular(r))
        ..lineTo(rr, t + arm)
        ..moveTo(rr, b - arm)
        ..lineTo(rr, b - r)
        ..arcToPoint(Offset(rr - r, b), radius: const Radius.circular(r))
        ..lineTo(rr - arm, b)
        ..moveTo(l + arm, b)
        ..lineTo(l + r, b)
        ..arcToPoint(Offset(l, b - r), radius: const Radius.circular(r))
        ..lineTo(l, b - arm),
      paint,
    );
  }

  @override
  bool shouldRepaint(_ScanBeamPainter old) =>
      old.value != value ||
      old.color != color ||
      old.cornerColor != cornerColor ||
      old.strong != strong ||
      old.corners != corners;
}
