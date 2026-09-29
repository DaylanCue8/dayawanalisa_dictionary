import 'package:flutter/material.dart';

/// The app's shared muted-honey palette, so every tab (both translators
/// and Settings) reads as one design: warm and lively, soft on the eyes.
class DayawColors {
  DayawColors._();

  static const Color amber = Color(0xFFD9A441);
  static const Color gold = Color(0xFFF3E3B3);
  static const Color yellow = Color(0xFFEBCB7C);
  static const Color deepBrown = Color(0xFF4E342E);
  static const Color softBrown = Color(0xFF6D4C41);
  static const Color cream = Color(0xFFFFFBF5);

  /// Muted stand-in for red: errors and destructive actions.
  static const Color brick = Color(0xFFB35C52);
}

/// Honey-gradient icon + bold brown label, used above every section.
class DayawSectionTitle extends StatelessWidget {
  final String text;
  final IconData icon;

  const DayawSectionTitle(this.text, this.icon, {super.key});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [DayawColors.amber, Color(0xFFB9853A)],
          ).createShader(bounds),
          child: Icon(icon, size: 20, color: Colors.white),
        ),
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
      ],
    );
  }
}

/// Tab header: gradient headline, a short subtitle and a strip of
/// Baybayin that shimmers with [shimmer] (a looping 0..1 animation the
/// tab already owns, so one ticker drives the whole screen).
class DayawHeroHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final String baybayin;
  final Animation<double> shimmer;

  const DayawHeroHeader({
    super.key,
    required this.title,
    required this.subtitle,
    required this.baybayin,
    required this.shimmer,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            colors: [
              DayawColors.deepBrown,
              Color(0xFFA9743A),
              Color(0xFFC9A15A),
            ],
          ).createShader(bounds),
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              height: 1.1,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          subtitle,
          style: const TextStyle(fontSize: 13, color: Colors.black54),
        ),
        const SizedBox(height: 8),
        AnimatedBuilder(
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
          child: Text(
            baybayin,
            style: const TextStyle(
              fontFamily: 'BaybayinCustom',
              fontSize: 20,
              color: Colors.white,
              letterSpacing: 2,
            ),
          ),
        ),
      ],
    );
  }
}
