import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/app_language.dart';
import '../services/app_settings.dart';
import '../services/haptics.dart';
import '../widgets/dayaw_style.dart';
import 'settings_screen.dart';
import 'translate_view.dart';
import '../widgets/glass.dart';
import '../widgets/liquid_glass_selector.dart';

/// Top-level shell: header and two destinations - Recognize (both
/// translators on one page, see [TranslateView]) and Settings.
class DayawLandingScreen extends StatefulWidget {
  const DayawLandingScreen({super.key});

  @override
  State<DayawLandingScreen> createState() => _DayawLandingScreenState();
}

class _DayawLandingScreenState extends State<DayawLandingScreen> {
  int selectedDestination = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      // Content runs under the frosted nav bar, like iOS.
      extendBody: true,
      body: GlassBackground(
        child: SafeArea(
          bottom: false,
          child: Column(
            children: [
              const SizedBox(height: 8),
              _buildHeader(),
              const SizedBox(height: 14),
              Expanded(
                // Cross-fade + slight rise when switching tabs.
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 280),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, animation) => FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0, 0.02),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
                  child: KeyedSubtree(
                    key: ValueKey(selectedDestination),
                    // Pages scroll on under the floating nav bar; each
                    // adds its own end padding (floatingNavPagePadding).
                    child: _buildSelectedDestination(),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      // Floating capsule with two tabs. Tap a tab, or long-press / drag
      // the yellow pill across them.
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(48, 0, 48, 10),
          child: GlassContainer(
            padding: const EdgeInsets.all(4),
            borderRadius: const BorderRadius.all(Radius.circular(28)),
            child: LiquidGlassSelector(
              count: _destinations.length,
              selectedIndex: selectedDestination,
              height: 48,
              pillRadius: const BorderRadius.all(Radius.circular(24)),
              onChanged: (index) {
                setState(() {
                  selectedDestination = index;
                });
              },
              itemBuilder: (context, index, selectedness) {
                final (icon, selectedIcon, en, fil) = _destinations[index];
                final label = context.tr(en, fil);
                // Muted when idle, charcoal on the yellow pill.
                final color = Color.lerp(
                  DayawColors.textMuted,
                  DayawColors.onSun,
                  selectedness,
                );
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        selectedness > 0.5 ? selectedIcon : icon,
                        color: color,
                        size: 19,
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: color,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
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
      ),
    );
  }

  // (icon, selected icon, English label, Filipino label)
  static const List<(IconData, IconData, String, String)> _destinations = [
    (
      Icons.document_scanner_outlined,
      Icons.document_scanner,
      'Recognize',
      'Kilalanin',
    ),
    (Icons.settings_outlined, Icons.settings, 'Settings', 'Mga Setting'),
  ];

  Widget _buildSelectedDestination() {
    switch (selectedDestination) {
      case 1:
        return const SettingsScreen();
      case 0:
      default:
        return const TranslateView();
    }
  }

  static const double _capsuleHeight = 44;
  static const BorderRadius _capsuleRadius = BorderRadius.all(
    Radius.circular(_capsuleHeight / 2),
  );
  static const EdgeInsets _capsulePadding = EdgeInsets.symmetric(
    horizontal: 22,
  );

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      // [language]        [logo]        [theme]
      child: Row(
        children: [
          _buildHeaderIconButton(
            icon: Icons.language,
            tooltip: context.tr('Language', 'Lengwahe'),
            onTap: _openLanguagePicker,
          ),
          const Spacer(),
          // The logo on a raised neumorphic capsule. The artwork has dark
          // letters, so in dark mode the capsule is dirty white to keep
          // it readable.
          Container(
            height: _capsuleHeight,
            padding: _capsulePadding,
            decoration: neuRaised(
              borderRadius: _capsuleRadius,
              depth: 0.5,
              color: DayawColors.dark ? const Color(0xFFE9E4DA) : null,
            ),
            child: Center(
              child: Image.asset(
                'assets/images/dayawlogo.png',
                height: 28,
                errorBuilder: (ctx, err, stack) => Text(
                  'DAYAW',
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    fontSize: 22,
                    letterSpacing: 3,
                    color: DayawColors.charcoal,
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
          _buildHeaderIconButton(
            icon: DayawColors.dark
                ? Icons.dark_mode_outlined
                : Icons.light_mode_outlined,
            tooltip: context.tr('Theme', 'Tema'),
            onTap: _openThemePicker,
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    // A raised rounded-square key, like an iOS neumorphic button.
    const radius = BorderRadius.all(Radius.circular(14));
    return Container(
      width: _capsuleHeight,
      height: _capsuleHeight,
      decoration: neuRaised(borderRadius: radius, depth: 0.5),
      child: Material(
        color: Colors.transparent,
        child: Tooltip(
          message: tooltip,
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: Icon(icon, color: DayawColors.textMuted, size: 21),
          ),
        ),
      ),
    );
  }

  Future<void> _openLanguagePicker() async {
    Haptics.selection();
    final code = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GlassContainer(
            tint: const Color(0xE6FFFBF5),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DayawSectionTitle(
                  context.tr('Language', 'Lengwahe'),
                  Icons.language,
                ),
                const SizedBox(height: 8),
                for (final (code, name) in appLanguages)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    leading: Container(
                      width: 38,
                      height: 38,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: DayawColors.charcoal,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Text(
                        code.toUpperCase(),
                        style: const TextStyle(
                          color: DayawColors.sun,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    title: Text(
                      name,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: DayawColors.text,
                      ),
                    ),
                    trailing: AppSettings.instance.language == code
                        ? Icon(
                            Icons.check_circle,
                            color: DayawColors.amber,
                          )
                        : null,
                    onTap: () => Navigator.of(context).pop(code),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (code != null) AppSettings.instance.language = code;
  }

  Future<void> _openThemePicker() async {
    Haptics.selection();
    final theme = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
          child: GlassContainer(
            tint: const Color(0xE6FFFBF5),
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DayawSectionTitle(
                  context.tr('Theme', 'Tema'),
                  Icons.contrast,
                ),
                const SizedBox(height: 8),
                for (final theme in DayawTheme.values)
                  ListTile(
                    contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                    leading: Icon(_themeIcon(theme), color: DayawColors.amber),
                    title: Text(
                      _themeLabel(context, theme),
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        color: DayawColors.text,
                      ),
                    ),
                    trailing: AppSettings.instance.theme == theme.name
                        ? Icon(
                            Icons.check_circle,
                            color: DayawColors.amber,
                          )
                        : null,
                    onTap: () => Navigator.of(context).pop(theme.name),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
    if (theme != null) AppSettings.instance.theme = theme;
  }

  String _themeLabel(BuildContext context, DayawTheme theme) {
    switch (theme) {
      case DayawTheme.light:
        return context.tr('Light', 'Maliwanag');
      case DayawTheme.dark:
        return context.tr('Dark', 'Madilim');
      case DayawTheme.system:
        return context.tr('Match device', 'Ayon sa device');
    }
  }

  IconData _themeIcon(DayawTheme theme) => switch (theme) {
    DayawTheme.light => Icons.light_mode_outlined,
    DayawTheme.dark => Icons.dark_mode_outlined,
    DayawTheme.system => Icons.brightness_auto_outlined,
  };
}