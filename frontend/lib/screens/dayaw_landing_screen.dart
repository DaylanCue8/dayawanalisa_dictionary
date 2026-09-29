import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/app_language.dart';
import '../services/app_settings.dart';
import '../widgets/dayaw_style.dart';
import 'baybayin_to_tagalog_view.dart';
import 'tagalog_to_baybayin_view.dart';
import 'settings_screen.dart';
import '../widgets/glass.dart';
import '../widgets/liquid_glass_selector.dart';

/// Top-level shell: header, mode dropdown, and swaps between the two
/// self-contained mode widgets. Each mode now owns its own state — since
/// BaybayinToTagalogView and TagalogToBaybayinView are different widget
/// types, Flutter disposes the old one and creates a fresh instance of
/// the new one whenever the mode changes, so switching modes resets that
/// mode's state automatically (no manual clearing needed here anymore).
class DayawLandingScreen extends StatefulWidget {
  const DayawLandingScreen({super.key});

  @override
  State<DayawLandingScreen> createState() => _DayawLandingScreenState();
}

class _DayawLandingScreenState extends State<DayawLandingScreen> {
  int selectedDestination = 1;

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
              const SizedBox(height: 10),
              _buildHeader(),
              const SizedBox(height: 20),
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
                    child: Padding(
                      // Keeps content clear of the floating nav bar.
                      padding: EdgeInsets.only(
                        bottom: 80 + MediaQuery.of(context).padding.bottom,
                      ),
                      child: _buildSelectedDestination(),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      // Floating frosted capsule, like the iOS tab bar. Tap a tab, or
      // long-press / drag the yellow pill across the tabs.
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: GlassContainer(
            padding: const EdgeInsets.all(5),
            borderRadius: const BorderRadius.all(Radius.circular(32)),
            child: LiquidGlassSelector(
              count: _destinations.length,
              selectedIndex: selectedDestination,
              height: 58,
              pillRadius: const BorderRadius.all(Radius.circular(27)),
              onChanged: (index) {
                setState(() {
                  selectedDestination = index;
                });
              },
              itemBuilder: (context, index, selectedness) {
                final (icon, selectedIcon, en, fil) = _destinations[index];
                final label = context.tr(en, fil);
                final color = Color.lerp(
                  Colors.brown,
                  Colors.black87,
                  selectedness,
                );
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        selectedness > 0.5 ? selectedIcon : icon,
                        color: color,
                        size: 22,
                      ),
                      const SizedBox(height: 2),
                      Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: color,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
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
      Icons.translate,
      Icons.translate,
      'Filipino to Baybayin',
      'Filipino sa Baybayin',
    ),
    (
      Icons.document_scanner_outlined,
      Icons.document_scanner,
      'Baybayin to Latin',
      'Baybayin sa Latin',
    ),
    (Icons.settings_outlined, Icons.settings, 'Settings', 'Mga Setting'),
  ];

  Widget _buildSelectedDestination() {
    switch (selectedDestination) {
      case 0:
        return const TagalogToBaybayinView();
      case 2:
        return const SettingsScreen();
      case 1:
      default:
        return const BaybayinToTagalogView();
    }
  }

  // Both header capsules share one size and shape, so the logo and the
  // language button read as a matching pair.
  static const double _capsuleHeight = 54;
  static const BorderRadius _capsuleRadius = BorderRadius.all(
    Radius.circular(_capsuleHeight / 2),
  );
  static const EdgeInsets _capsulePadding = EdgeInsets.symmetric(
    horizontal: 18,
  );

  Widget _buildHeader() {
    // Logo capsule on the left, language button on the right.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          GlassContainer(
            height: _capsuleHeight,
            borderRadius: _capsuleRadius,
            padding: _capsulePadding,
            child: Center(
              child: Image.asset(
                'assets/images/dayawlogo.png',
                height: 42,
                errorBuilder: (ctx, err, stack) {
                  return const Text(
                    "DAYAW",
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 22,
                      color: Colors.brown,
                    ),
                  );
                },
              ),
            ),
          ),
          const Spacer(),
          _buildLanguageButton(),
        ],
      ),
    );
  }

  /// "Language" / "Lengwahe" button (plain, no glass panel); opens the
  /// English / Filipino picker. Same height as the logo capsule so the
  /// two stay aligned.
  Widget _buildLanguageButton() {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: _openLanguagePicker,
        borderRadius: _capsuleRadius,
        child: Container(
          height: _capsuleHeight,
          padding: _capsulePadding,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.language,
                color: DayawColors.deepBrown,
                size: 20,
              ),
              const SizedBox(width: 6),
              Text(
                context.tr('Language', 'Lengwahe'),
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: DayawColors.deepBrown,
                ),
              ),
              const SizedBox(width: 2),
              const Icon(
                Icons.expand_more,
                color: DayawColors.deepBrown,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openLanguagePicker() async {
    if (AppSettings.instance.hapticsEnabled) HapticFeedback.selectionClick();
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
                        color: DayawColors.deepBrown,
                        borderRadius: BorderRadius.circular(11),
                      ),
                      child: Text(
                        code.toUpperCase(),
                        style: const TextStyle(
                          color: DayawColors.gold,
                          fontWeight: FontWeight.w800,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    title: Text(
                      name,
                      style: const TextStyle(
                        fontWeight: FontWeight.w800,
                        color: DayawColors.deepBrown,
                      ),
                    ),
                    trailing: AppSettings.instance.language == code
                        ? const Icon(
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
}
