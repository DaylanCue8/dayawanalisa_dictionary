import 'package:flutter/material.dart';
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
                final (icon, selectedIcon, label) = _destinations[index];
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

  static const List<(IconData, IconData, String)> _destinations = [
    (Icons.translate, Icons.translate, 'Filipino to Baybayin'),
    (
      Icons.document_scanner_outlined,
      Icons.document_scanner,
      'Baybayin to Filipino',
    ),
    (Icons.settings_outlined, Icons.settings, 'Settings'),
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

  Widget _buildHeader() {
    // Capsule that hugs the logo (with even breathing room around it)
    // instead of stretching across the screen.
    return Center(
      child: GlassContainer(
        borderRadius: const BorderRadius.all(Radius.circular(29)),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
        child: Image.asset(
          'assets/images/dayawlogo.png',
          height: 50,
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
    );
  }
}
