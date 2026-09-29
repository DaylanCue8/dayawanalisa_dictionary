import 'dart:ui';

import 'package:flutter/material.dart';

import '../services/app_settings.dart';

/// iOS-style frosted glass: blurs whatever is behind it, tints it with a
/// translucent fill, and adds a thin light border so the edge reads on
/// both light and warm backgrounds.
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
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: solid
                  ? [_opaque(tint), _opaque(tint)]
                  : [tint, tint.withValues(alpha: tint.a * 0.7)],
            ),
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
}

/// The tint with its see-through part filled in: white glass becomes a
/// near-white card, dark glass a near-black one.
Color _opaque(Color tint) => tint.withValues(alpha: 0.94);

/// Blurred full-width bar (app bar / bottom navigation), like the iOS
/// translucent chrome that content scrolls underneath.
class GlassBar extends StatelessWidget {
  final Widget child;
  final bool borderOnTop;

  const GlassBar({super.key, required this.child, this.borderOnTop = false});

  @override
  Widget build(BuildContext context) {
    final edge = BorderSide(color: Colors.white.withValues(alpha: 0.6));
    return ListenableBuilder(
      listenable: AppSettings.instance,
      builder: (context, _) {
        final solid = AppSettings.instance.reduceTransparency;
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

/// Soft warm gradient with a few blurred color blobs. Glass needs
/// something colorful behind it to show the frosted effect.
class GlassBackground extends StatelessWidget {
  final Widget child;

  const GlassBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
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
        const _Blob(top: -80, left: -60, size: 260, color: Color(0x66FFB74D)),
        const _Blob(top: 220, right: -90, size: 280, color: Color(0x55A1887F)),
        const _Blob(bottom: -60, left: 20, size: 240, color: Color(0x44FFD54F)),
        Positioned.fill(child: child),
      ],
    );
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
