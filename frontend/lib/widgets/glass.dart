import 'package:flutter/material.dart';

import 'dayaw_style.dart';

// The app's panels, bars and background, in a minimalist neumorphic look:
// every panel is made of the same material as the page and lifted out of
// it by a soft highlight (top left) and shade (bottom right).
//
// The class names are kept from the earlier frosted-glass look so the
// screens don't change.

/// What a caller's [GlassContainer.tint] asks for.
enum _Tone { neutral, accent, overlay }

_Tone _toneOf(Color tint) {
  // A dark see-through tint sits over a photo: keep it a dark overlay.
  if (tint.computeLuminance() < 0.2) return _Tone.overlay;
  // A warm, saturated tint marks a highlighted card.
  final hsl = HSLColor.fromColor(tint);
  if (hsl.saturation > 0.5 && hsl.hue > 35 && hsl.hue < 65) {
    return _Tone.accent;
  }
  return _Tone.neutral;
}

/// A raised neumorphic card. [tint] picks the tone: light tints give a
/// plain card, a yellow tint a card washed with the accent, and a dark
/// tint a dark overlay (for panels over photos).
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
    DayawTheme.of(context);
    final tone = _toneOf(tint);
    final BoxDecoration decoration;
    switch (tone) {
      case _Tone.overlay:
        decoration = BoxDecoration(
          color: DayawColors.charcoal.withValues(alpha: 0.72),
          borderRadius: borderRadius,
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        );
      // Monochrome, like the rest: highlighted cards are plain raised.
      case _Tone.accent:
        decoration = neuRaised(borderRadius: borderRadius);
      case _Tone.neutral:
        decoration = neuRaised(borderRadius: borderRadius);
    }
    return Container(
      margin: margin,
      height: height,
      padding: padding,
      decoration: decoration,
      child: child,
    );
  }
}

/// Full-width bar (app bar / bottom navigation): the page's own material
/// with a soft shade along its inner edge.
class GlassBar extends StatelessWidget {
  final Widget child;
  final bool borderOnTop;

  const GlassBar({super.key, required this.child, this.borderOnTop = false});

  @override
  Widget build(BuildContext context) {
    DayawTheme.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: DayawColors.bg,
        boxShadow: [
          BoxShadow(
            color: DayawColors.shadowDark.withValues(alpha: 0.45),
            offset: Offset(0, borderOnTop ? -3 : 3),
            blurRadius: 10,
          ),
        ],
      ),
      child: child,
    );
  }
}

/// Page background: the flat dirty-white (or charcoal) ground.
class GlassBackground extends StatelessWidget {
  final Widget child;

  const GlassBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    DayawTheme.of(context);
    return ColoredBox(color: DayawColors.bg, child: child);
  }
}
