import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import 'embroidery.dart';

/// The app's shared muted-honey palette, used by every theme.
class DayawColors {
  DayawColors._();

  static const Color amber = Color(0xFFD9A441);
  static const Color gold = Color(0xFFF3E3B3);
  static const Color yellow = Color(0xFFEBCB7C);
  static const Color deepBrown = Color(0xFF4E342E);
  static const Color softBrown = Color(0xFF6D4C41);
  static const Color cream = Color(0xFFFFFBF5);

  /// Flat page background (Bold and Embroidery themes).
  static const Color paper = Color(0xFFF7EFE3);

  /// Muted stand-in for red: errors and destructive actions.
  static const Color brick = Color(0xFFB35C52);
}

/// The three looks the app can wear (Settings > Theme).
enum DayawTheme {
  /// Soft honey gradients, frosted glass and shimmer.
  gradient,

  /// The same palette in flat, solid tones.
  bold,

  /// Linen fabric, stitched patches and cross-stitch bands.
  embroidery;

  static DayawTheme get current => DayawTheme.values.firstWhere(
    (t) => t.name == AppSettings.instance.theme,
    orElse: () => DayawTheme.gradient,
  );

  /// The theme for [context], rebuilding it when the theme changes.
  static DayawTheme of(BuildContext context) {
    context.dependOnInheritedWidgetOfExactType<ThemeScope>();
    return current;
  }
}

/// Sits above every screen (see DayawApp's builder), so switching theme
/// repaints the shared panels, bars and titles live.
class ThemeScope extends InheritedNotifier<ValueNotifier<String>> {
  ThemeScope({super.key, required super.child})
    : super(notifier: AppSettings.instance.themeNotifier);
}

/// [gradient] in the Gradient theme, null otherwise - so a decoration can
/// always carry its flat `color` and gain the gradient on top of it
/// (a BoxDecoration paints the gradient over the color when both are set).
Gradient? themedGradient(Gradient gradient) =>
    DayawTheme.current == DayawTheme.gradient ? gradient : null;

/// Amber icon + bold brown label, used above every section. Gradient
/// theme: honey-gradient icon. Embroidery: a stitched thread runs on to
/// the right edge.
class DayawSectionTitle extends StatelessWidget {
  final String text;
  final IconData icon;

  const DayawSectionTitle(this.text, this.icon, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = DayawTheme.of(context);
    return Row(
      children: [
        if (theme == DayawTheme.gradient)
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [DayawColors.amber, Color(0xFFB9853A)],
            ).createShader(bounds),
            child: Icon(icon, size: 20, color: Colors.white),
          )
        else
          Icon(icon, size: 20, color: DayawColors.amber),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: DayawColors.deepBrown,
            ),
          ),
        ),
        if (theme == DayawTheme.embroidery) ...[
          const SizedBox(width: 10),
          const Expanded(child: StitchLine(color: Thread.amber)),
        ],
      ],
    );
  }
}

/// Tab header: headline, a short subtitle and a line of Baybayin.
/// Gradient theme: gradient headline and a Baybayin line that shimmers
/// with [shimmer] (a looping 0..1 animation the tab already owns).
/// Embroidery: a cross-stitch band underneath.
class DayawHeroHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final String baybayin;
  final Animation<double>? shimmer;

  const DayawHeroHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.baybayin,
    this.shimmer,
  });

  @override
  Widget build(BuildContext context) {
    final theme = DayawTheme.of(context);
    final gradient = theme == DayawTheme.gradient;
    final shimmer = this.shimmer;

    Widget headline = Text(
      title,
      style: TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w900,
        color: gradient ? Colors.white : DayawColors.deepBrown,
        height: 1.1,
      ),
    );
    if (gradient) {
      headline = ShaderMask(
        shaderCallback: (bounds) => const LinearGradient(
          colors: [DayawColors.deepBrown, Color(0xFFA9743A), Color(0xFFC9A15A)],
        ).createShader(bounds),
        child: headline,
      );
    }

    Widget script = Text(
      baybayin,
      style: TextStyle(
        fontFamily: 'BaybayinCustom',
        fontSize: 20,
        color: gradient && shimmer != null ? Colors.white : DayawColors.amber,
        letterSpacing: 2,
      ),
    );
    if (gradient && shimmer != null) {
      script = AnimatedBuilder(
        animation: shimmer,
        builder: (context, child) => ShaderMask(
          shaderCallback: (bounds) => LinearGradient(
            begin: Alignment(-1 + 3 * shimmer.value - 1, 0),
            end: Alignment(1 + 3 * shimmer.value - 1, 0),
            colors: const [
              Color(0x66795548),
              DayawColors.yellow,
              Color(0x66795548),
            ],
          ).createShader(bounds),
          child: child,
        ),
        child: script,
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        headline,
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(fontSize: 13, color: Colors.black54),
        ),
        const SizedBox(height: 8),
        script,
        if (theme == DayawTheme.embroidery) ...[
          const SizedBox(height: 10),
          const CrossStitchBand(),
        ],
      ],
    );
  }
}
