import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import 'dayaw_style.dart';
import 'embroidery.dart';

// The app's panels, bars and background. Each one draws itself in the
// current theme (Settings > Theme):
//   Gradient   - frosted glass over a soft gradient with color blobs
//   Bold       - the same glass panels over a flat paper color
//   Embroidery - fabric patches with running stitches over linen

/// A card. Gradient/Bold: iOS-style frosted glass (blurs what's behind,
/// translucent [tint], thin light border). Embroidery: a solid cloth
/// patch with a stitched hem.
class GlassContainer extends StatelessWidget {
  final Widget child;
  final BorderRadius borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final double blur;
  final Color tint;
  final double? height;

  const GlassContainer({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(20)),
    this.padding,
    this.margin,
    this.blur = 18,
    this.tint = const Color(0x8CFFFFFF),
    this.height,
  });

  @override
  Widget build(BuildContext context) {
    final theme = DayawTheme.of(context);
    if (theme == DayawTheme.embroidery) return _patch();
    return ListenableBuilder(
      listenable: AppSettings.instance,
      builder: (context, _) {
        // "Reduce transparency" setting: a solid panel, no live blur.
        final solid = AppSettings.instance.reduceTransparency;
        final panel = Container(
          height: height,
          padding: padding,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            color: solid ? _opaque(tint) : tint,
            gradient: theme == DayawTheme.gradient && !solid
                ? LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      tint,
                      tint.withValues(alpha: tint.a * 0.7),
                    ],
                  )
                : null,
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.6),
              width: 1,
            ),
          ),
          child: child,
        );
        return Container(
          margin: margin,
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            boxShadow: const [
              BoxShadow(
                color: Color(0x14000000),
                blurRadius: 24,
                offset: Offset(0, 8),
              ),
            ],
          ),
          child: ClipRRect(
            borderRadius: borderRadius,
            child: solid
                ? panel
                : BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: blur, sigmaY: blur),
                    child: panel,
                  ),
          ),
        );
      },
    );
  }

  /// Embroidery: [tint] laid over the linen as solid cloth, a running
  /// stitch just inside the edge, and a small shadow as if sewn on.
  Widget _patch() {
    final fabric = Color.alphaBlend(tint, DayawColors.paper);
    // Tight panels (selectors, the nav bar) get a finer stitch closer to
    // the edge, so it runs around the content instead of under it.
    final tight = (padding?.horizontal ?? 0) < 16;
    return Container(
      margin: margin,
      height: height,
      decoration: BoxDecoration(
        color: fabric,
        borderRadius: borderRadius,
        boxShadow: const [
          BoxShadow(
            color: Color(0x26000000),
            blurRadius: 3,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: CustomPaint(
        painter: StitchBorderPainter(
          color: Thread.on(fabric).withValues(alpha: 0.75),
          radius: borderRadius.topLeft.x,
          inset: tight ? 2.5 : 6,
          stitch: tight ? 5 : 7,
          gap: tight ? 3.5 : 4.5,
          width: tight ? 1.2 : 1.6,
        ),
        child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
      ),
    );
  }
}

/// The tint with its see-through part filled in: white glass becomes a
/// near-white card, dark glass a near-black one.
Color _opaque(Color tint) => tint.withValues(alpha: 0.94);

/// Full-width bar (app bar / bottom navigation). Gradient/Bold: blurred,
/// translucent, like iOS chrome. Embroidery: linen cloth with a stitched
/// hem along its edge.
class GlassBar extends StatelessWidget {
  final Widget child;
  final bool borderOnTop;

  const GlassBar({super.key, required this.child, this.borderOnTop = false});

  @override
  Widget build(BuildContext context) {
    final theme = DayawTheme.of(context);
    return ListenableBuilder(
      listenable: AppSettings.instance,
      builder: (context, _) {
        final solid = AppSettings.instance.reduceTransparency;
        if (theme == DayawTheme.embroidery) {
          return DecoratedBox(
            decoration: const BoxDecoration(color: DayawColors.paper),
            child: Stack(
              children: [
                Positioned.fill(child: child),
                Positioned(
                  left: 12,
                  right: 12,
                  top: borderOnTop ? 3 : null,
                  bottom: borderOnTop ? null : 3,
                  child: const StitchLine(color: Thread.brown, width: 1.3),
                ),
              ],
            ),
          );
        }
        final edge = BorderSide(color: Colors.white.withValues(alpha: 0.6));
        final bar = DecoratedBox(
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: solid ? 0.96 : 0.55),
            border: borderOnTop ? Border(top: edge) : Border(bottom: edge),
          ),
          child: child,
        );
        if (solid) return bar;
        return ClipRect(
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
            child: bar,
          ),
        );
      },
    );
  }
}

/// Page background. Gradient: soft warm gradient with blurred color
/// blobs (glass needs color behind it to show the frost). Bold: flat
/// paper. Embroidery: linen fabric.
class GlassBackground extends StatelessWidget {
  final Widget child;

  const GlassBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    switch (DayawTheme.of(context)) {
      case DayawTheme.embroidery:
        return LinenBackground(color: DayawColors.paper, child: child);
      case DayawTheme.bold:
        return ColoredBox(color: DayawColors.paper, child: child);
      case DayawTheme.gradient:
        return Stack(
          children: [
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFFFFF8EE),
                      Color(0xFFF6E7D4),
                      Color(0xFFEFE3F0),
                    ],
                  ),
                ),
              ),
            ),
            const _Blob(
              top: -80,
              left: -60,
              size: 260,
              color: Color(0x66FFB74D),
            ),
            const _Blob(
              top: 220,
              right: -90,
              size: 280,
              color: Color(0x55A1887F),
            ),
            const _Blob(
              bottom: -60,
              left: 20,
              size: 240,
              color: Color(0x44FFD54F),
            ),
            Positioned.fill(child: child),
          ],
        );
    }
  }
}

class _Blob extends StatelessWidget {
  final double? top, left, right, bottom;
  final double size;
  final Color color;

  const _Blob({
    this.top,
    this.left,
    this.right,
    this.bottom,
    required this.size,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: top,
      left: left,
      right: right,
      bottom: bottom,
      child: IgnorePointer(
        child: Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [color, color.withValues(alpha: 0)],
            ),
          ),
        ),
      ),
    );
  }
}
