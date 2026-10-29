import 'package:flutter/material.dart';

import '../services/app_settings.dart';

/// The app's palette: sunflower yellow on charcoal black, over a warm
/// dirty-white (light) or charcoal (dark) neumorphic ground.
///
/// The themed colors are getters that follow [DayawColors.dark], which
/// DayawApp keeps in sync with the chosen theme (see [DayawTheme]); a
/// theme switch rebuilds the whole tree so every getter is re-read.
class DayawColors {
  DayawColors._();

  /// True while the dark palette is active. Set by DayawApp only.
  static bool dark = false;

  // ---- brand: the same in both modes ----

  /// Sunflower yellow - the accent.
  static const Color sun = Color(0xFFF2C230);

  /// Charcoal black - the other half of the black-and-yellow pair.
  static const Color charcoal = Color(0xFF1E1C19);

  /// Text/icons drawn on [sun].
  static const Color onSun = charcoal;

  // ---- neumorphic ground ----

  /// Page background: warm dirty white / deep charcoal.
  static Color get bg =>
      dark ? const Color(0xFF242320) : const Color(0xFFECE7DE);

  /// Raised panels: exactly the material of [bg] - in neumorphism the
  /// shapes are moulded out of the page, only light and shadow set them
  /// apart.
  static Color get surface => bg;

  /// Sunken wells (inputs, tracks): a hair darker than [bg].
  static Color get well =>
      dark ? const Color(0xFF1F1E1B) : const Color(0xFFE5DFD5);

  /// Highlight of the neumorphic pair (light falls from the top left).
  static Color get shadowLight =>
      dark ? const Color(0xFF33312D) : const Color(0xFFFFFDF8);

  /// Shade of the neumorphic pair (bottom right).
  static Color get shadowDark =>
      dark ? const Color(0xFF141311) : const Color(0xFFC6BEB1);

  /// Hairline dividers and outlines.
  static Color get line =>
      dark ? const Color(0xFF363430) : const Color(0xFFDDD6CB);

  // ---- text ----

  static Color get text =>
      dark ? const Color(0xFFEFE9DD) : const Color(0xFF1E1C19);

  static Color get textMuted =>
      dark ? const Color(0xFF9D978B) : const Color(0xFF77716A);

  // ---- names kept from the earlier palette, mapped onto the new one ----

  /// Accent for icons and highlights; a deeper yellow on the light ground
  /// so it still reads against dirty white.
  static Color get amber => dark ? sun : const Color(0xFFC99A0E);
  static Color get yellow => sun;
  static Color get gold => sun;

  /// Primary text color (was a deep brown).
  static Color get deepBrown => text;
  static Color get softBrown => textMuted;
  static Color get cream => surface;
  static Color get paper => bg;

  /// Muted red: errors and destructive actions.
  static Color get brick =>
      dark ? const Color(0xFFE0847A) : const Color(0xFFB3473C);

  /// Muted green for good confidence / success.
  static Color get leaf =>
      dark ? const Color(0xFF8FC48A) : const Color(0xFF3E7D3A);
}

/// Soft dual shadows: the neumorphic "raised" look. Light falls from the
/// top left, so a highlight sits there and a shade at the bottom right.
/// [depth] scales the offset and blur (0.5 for small chips, 1 for cards).
/// Wide, very soft blurs keep it smooth rather than outlined.
List<BoxShadow> neuShadows({double depth = 1}) => [
  BoxShadow(
    color: DayawColors.shadowDark.withValues(
      alpha: DayawColors.dark ? 0.85 : 0.65,
    ),
    offset: Offset(7 * depth, 7 * depth),
    blurRadius: 18 * depth,
  ),
  BoxShadow(
    color: DayawColors.shadowLight,
    offset: Offset(-7 * depth, -7 * depth),
    blurRadius: 18 * depth,
  ),
];

/// A raised neumorphic decoration in the ground's own material.
BoxDecoration neuRaised({
  BorderRadius borderRadius = const BorderRadius.all(Radius.circular(20)),
  Color? color,
  double depth = 1,
}) => BoxDecoration(
  color: color ?? DayawColors.surface,
  borderRadius: borderRadius,
  boxShadow: neuShadows(depth: depth),
);

/// A sunken well, pressed into the surface: real inner shadows, shade
/// along the top-left rim and light along the bottom-right one.
Decoration neuSunken({
  BorderRadius borderRadius = const BorderRadius.all(Radius.circular(16)),
  double depth = 1,
}) => NeuInsetDecoration(
  borderRadius: borderRadius,
  color: DayawColors.bg,
  shade: DayawColors.shadowDark.withValues(
    alpha: DayawColors.dark ? 0.95 : 0.75,
  ),
  light: DayawColors.shadowLight,
  depth: depth,
);

/// Paints a rounded box with inner (inset) shadows, which BoxDecoration
/// can't do: each shadow is the area outside a shifted copy of the box,
/// blurred and clipped to the box.
class NeuInsetDecoration extends Decoration {
  final BorderRadius borderRadius;
  final Color color;
  final Color shade;
  final Color light;
  final double depth;

  const NeuInsetDecoration({
    required this.borderRadius,
    required this.color,
    required this.shade,
    required this.light,
    this.depth = 1,
  });

  @override
  bool hitTest(Size size, Offset position, {TextDirection? textDirection}) =>
      borderRadius.toRRect(Offset.zero & size).contains(position);

  @override
  BoxPainter createBoxPainter([VoidCallback? onChanged]) =>
      _NeuInsetPainter(this);

  @override
  bool operator ==(Object other) =>
      other is NeuInsetDecoration &&
      other.borderRadius == borderRadius &&
      other.color == color &&
      other.shade == shade &&
      other.light == light &&
      other.depth == depth;

  @override
  int get hashCode => Object.hash(borderRadius, color, shade, light, depth);
}

class _NeuInsetPainter extends BoxPainter {
  final NeuInsetDecoration d;
  _NeuInsetPainter(this.d);

  @override
  void paint(Canvas canvas, Offset offset, ImageConfiguration configuration) {
    final size = configuration.size;
    if (size == null || size.isEmpty) return;
    final rect = offset & size;
    final rrect = d.borderRadius.toRRect(rect);
    final blur = 6.0 * d.depth;
    final shift = 4.0 * d.depth;

    canvas.save();
    canvas.clipRRect(rrect);
    canvas.drawRRect(rrect, Paint()..color = d.color);
    void inner(Color color, Offset by) {
      final ring = Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(rect.inflate(blur * 4))
        ..addRRect(rrect.shift(by));
      canvas.drawPath(
        ring,
        Paint()
          ..color = color
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, blur),
      );
    }

    inner(d.shade, Offset(shift, shift));
    inner(d.light, Offset(-shift, -shift));
    canvas.restore();
  }
}

/// The theme setting: Light, Dark, or follow the device (Settings > Theme).
enum DayawTheme {
  light,
  dark,
  system;

  static DayawTheme get current => DayawTheme.values.firstWhere(
    (t) => t.name == AppSettings.instance.theme,
    orElse: () => DayawTheme.system,
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

/// Padding for a page that scrolls under the floating bottom bar: the
/// content runs all the way beneath the bar (no band behind it), with
/// room at the end so the last item can scroll clear of it.
EdgeInsets floatingNavPagePadding(BuildContext context) =>
    EdgeInsets.fromLTRB(20, 0, 20, 96 + MediaQuery.paddingOf(context).bottom);

/// Neumorphism is flat: the old gradient fills are no longer drawn, so
/// every decoration falls back to its solid `color`.
Gradient? themedGradient(Gradient gradient) => null;

/// A quiet section label: a small yellow diamond (after the banig weave)
/// and the title in small muted bold. [icon] is kept for the callers.
class DayawSectionTitle extends StatelessWidget {
  final String text;
  final IconData icon;

  const DayawSectionTitle(this.text, this.icon, {super.key});

  @override
  Widget build(BuildContext context) {
    DayawTheme.of(context);
    return Row(
      children: [
        Transform.rotate(
          angle: 0.785398,
          child: Container(width: 6, height: 6, color: DayawColors.amber),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            text,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.2,
              color: DayawColors.textMuted,
            ),
          ),
        ),
      ],
    );
  }
}

/// Page header: a headline and a short subtitle. [baybayin] and
/// [shimmer] are accepted for compatibility; neither is shown.
class DayawHeroHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  final String baybayin;
  final Animation<double>? shimmer;

  const DayawHeroHeader({
    super.key,
    required this.title,
    required this.subtitle,
    this.baybayin = '',
    this.shimmer,
  });

  @override
  Widget build(BuildContext context) {
    DayawTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: DayawColors.text,
            height: 1.15,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: TextStyle(fontSize: 13, color: DayawColors.textMuted),
        ),
      ],
    );
  }
}
