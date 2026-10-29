import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'dayaw_style.dart';

// Filipino accents for the minimalist look, kept small and quiet so they
// season the design instead of decorating it:
//   BanigBand  - a band of woven diamonds, after the banig (woven mat)
//                and inabel cloth borders
//   BanigRule  - a hairline with a diamond knot, for section titles
//   SunMark    - the eight-rayed sun, as a faint watermark

/// A thin band of interlocking diamonds, like the border of a banig mat:
/// yellow diamonds alternating with small dots in the muted text color.
class BanigBand extends StatelessWidget {
  final double height;
  const BanigBand({super.key, this.height = 10});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: height,
    width: double.infinity,
    child: CustomPaint(
      painter: _BanigPainter(DayawColors.amber, DayawColors.textMuted),
    ),
  );
}

class _BanigPainter extends CustomPainter {
  final Color accent;
  final Color muted;
  _BanigPainter(this.accent, this.muted);

  @override
  void paint(Canvas canvas, Size size) {
    final h = size.height;
    final y = h / 2;
    final step = h * 1.6;
    final line = Paint()
      ..color = muted.withValues(alpha: 0.25)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, 0.5), Offset(size.width, 0.5), line);
    canvas.drawLine(Offset(0, h - 0.5), Offset(size.width, h - 0.5), line);

    final diamond = Paint()..color = accent.withValues(alpha: 0.85);
    final dot = Paint()..color = muted.withValues(alpha: 0.45);
    final count = (size.width / step).floor();
    final offset = (size.width - count * step) / 2;
    for (var i = 0; i < count; i++) {
      final cx = offset + step * (i + 0.5);
      if (i.isEven) {
        final r = h * 0.32;
        canvas.drawPath(
          Path()
            ..moveTo(cx, y - r)
            ..lineTo(cx + r, y)
            ..lineTo(cx, y + r)
            ..lineTo(cx - r, y)
            ..close(),
          diamond,
        );
      } else {
        canvas.drawCircle(Offset(cx, y), h * 0.1, dot);
      }
    }
  }

  @override
  bool shouldRepaint(_BanigPainter old) =>
      old.accent != accent || old.muted != muted;
}

/// A hairline that ends in a small yellow diamond knot.
class BanigRule extends StatelessWidget {
  const BanigRule({super.key});

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 8,
    child: CustomPaint(
      painter: _RulePainter(DayawColors.amber, DayawColors.line),
    ),
  );
}

class _RulePainter extends CustomPainter {
  final Color accent;
  final Color line;
  _RulePainter(this.accent, this.line);

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    final r = size.height / 2;
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width - r * 2 - 3, y),
      Paint()
        ..color = line
        ..strokeWidth = 1,
    );
    final cx = size.width - r;
    canvas.drawPath(
      Path()
        ..moveTo(cx, y - r)
        ..lineTo(cx + r, y)
        ..lineTo(cx, y + r)
        ..lineTo(cx - r, y)
        ..close(),
      Paint()..color = accent,
    );
  }

  @override
  bool shouldRepaint(_RulePainter old) =>
      old.accent != accent || old.line != line;
}

/// The eight-rayed sun of the Philippine flag, drawn as a simple outline
/// mark. Used large and faint behind content.
class SunMark extends StatelessWidget {
  final double size;
  final Color? color;
  const SunMark({super.key, this.size = 120, this.color});

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: size,
    child: CustomPaint(painter: _SunPainter(color ?? DayawColors.amber)),
  );
}

class _SunPainter extends CustomPainter {
  final Color color;
  _SunPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final radius = size.shortestSide / 2;
    final paint = Paint()..color = color;
    canvas.drawCircle(c, radius * 0.34, paint);
    // Eight main rays, each a slim triangle flanked by two thin ones.
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4 - math.pi / 2;
      for (final spread in const [-0.16, 0.0, 0.16]) {
        final angle = a + spread;
        final width = spread == 0 ? 0.07 : 0.035;
        final length = spread == 0 ? 1.0 : 0.82;
        final tip = c + Offset(math.cos(angle), math.sin(angle)) * radius * length;
        final l = c +
            Offset(math.cos(angle - width), math.sin(angle - width)) * radius * 0.44;
        final r = c +
            Offset(math.cos(angle + width), math.sin(angle + width)) * radius * 0.44;
        canvas.drawPath(
          Path()
            ..moveTo(l.dx, l.dy)
            ..lineTo(tip.dx, tip.dy)
            ..lineTo(r.dx, r.dy)
            ..close(),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SunPainter old) => old.color != color;
}
