import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/app_settings.dart';
import '../widgets/glass.dart';
import '../widgets/info_modal.dart';
import '../widgets/liquid_glass_selector.dart';
import 'intro_screen.dart';

/// iOS-style grouped settings, each group a frosted glass card. Every
/// value is saved on the device (see [AppSettings]).
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  static const String appVersion = '1.0.0';

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(4, 0, 4, 12),
            child: Text(
              'Settings',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: Colors.brown,
              ),
            ),
          ),

          _Section(
            title: 'Camera',
            children: [
              _Tile(
                icon: Icons.edit_outlined,
                iconColor: Colors.orange,
                title: 'Default input',
                subtitle: 'What the camera starts on',
                trailing: SizedBox(
                  width: 128,
                  child: _SmallSelector(
                    labels: const ['Marker', 'Pen'],
                    selectedIndex: settings.cameraInputType == 'pen' ? 1 : 0,
                    onChanged: (i) =>
                        settings.cameraInputType = i == 1 ? 'pen' : 'marker',
                  ),
                ),
              ),
              _SwitchTile(
                icon: Icons.grid_4x4,
                iconColor: Colors.teal,
                title: 'Show grid by default',
                value: settings.cameraGridByDefault,
                onChanged: (v) => settings.cameraGridByDefault = v,
              ),
            ],
          ),

          _Section(
            title: 'Results',
            children: [
              _Tile(
                icon: Icons.filter_b_and_w_outlined,
                iconColor: Colors.indigo,
                title: 'Default filter',
                below: _SmallSelector(
                  labels: const ['Raw', 'Black and White', 'HOG'],
                  selectedIndex: const [
                    'Raw',
                    'Black and White',
                    'HOG',
                  ].indexOf(settings.resultFilter).clamp(0, 2),
                  onChanged: (i) => settings.resultFilter = const [
                    'Raw',
                    'Black and White',
                    'HOG',
                  ][i],
                ),
              ),
              _SwitchTile(
                icon: Icons.crop_free,
                iconColor: Colors.green,
                title: 'Show bounding boxes by default',
                value: settings.showBoundingBoxesByDefault,
                onChanged: (v) => settings.showBoundingBoxesByDefault = v,
              ),
              _Tile(
                icon: Icons.tune,
                iconColor: Colors.red,
                title: 'Minimum confidence',
                subtitle: 'Hide characters the model is less sure about',
                trailing: Text(
                  '${settings.minConfidence.round()}%',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Colors.brown,
                  ),
                ),
                below: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: Colors.brown,
                    inactiveTrackColor: Colors.brown.withValues(alpha: 0.15),
                    thumbColor: Colors.white,
                    overlayColor: Colors.brown.withValues(alpha: 0.1),
                    trackHeight: 4,
                  ),
                  child: Slider(
                    value: settings.minConfidence,
                    min: 0,
                    max: 90,
                    divisions: 90,
                    onChanged: (v) => settings.minConfidence = v,
                  ),
                ),
              ),
            ],
          ),

          _Section(
            title: 'Experience',
            children: [
              _SwitchTile(
                icon: Icons.vibration,
                iconColor: Colors.purple,
                title: 'Haptic feedback',
                subtitle: 'Vibrate when switching tabs and filters',
                value: settings.hapticsEnabled,
                onChanged: (v) => settings.hapticsEnabled = v,
              ),
              _SwitchTile(
                icon: Icons.blur_off,
                iconColor: Colors.blueGrey,
                title: 'Reduce transparency',
                subtitle: 'Solid panels instead of frosted glass',
                value: settings.reduceTransparency,
                onChanged: (v) => settings.reduceTransparency = v,
              ),
            ],
          ),

          _Section(
            title: 'About',
            children: [
              _Tile(
                icon: Icons.info_outline,
                iconColor: Colors.brown,
                title: 'About Dayaw',
                subtitle: 'The project and how to write for Baybayin',
                showChevron: true,
                onTap: () => showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (context) => const InfoModal(),
                ),
              ),
              _Tile(
                icon: Icons.auto_awesome,
                iconColor: const Color(0xFFFFB300),
                title: 'Show introduction',
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const IntroScreen(fromSettings: true),
                  ),
                ),
              ),
              _Tile(
                icon: Icons.table_chart_outlined,
                iconColor: Colors.amber.shade800,
                title: 'Baybayin chart',
                showChevron: true,
                onTap: () => _showChart(context),
              ),
              _Tile(
                icon: Icons.description_outlined,
                iconColor: Colors.grey,
                title: 'Open-source licenses',
                showChevron: true,
                // Left empty for now; swap back to showLicensePage(...) to
                // list the packages' licenses.
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const _EmptyLicensesPage(),
                  ),
                ),
              ),
              const _Tile(
                icon: Icons.verified_outlined,
                iconColor: Colors.blue,
                title: 'Version',
                trailing: Text(
                  appVersion,
                  style: TextStyle(color: Colors.black54),
                ),
              ),
            ],
          ),

          _Section(
            children: [
              _Tile(
                icon: Icons.restart_alt,
                iconColor: Colors.red,
                title: 'Reset settings',
                titleColor: Colors.red,
                onTap: () => _confirmReset(context),
              ),
            ],
          ),

          const SizedBox(height: 8),
          const Center(
            child: Text(
              '© 2026 DAYAW. All rights reserved.',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  void _showChart(BuildContext context) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        backgroundColor: Colors.white,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            InteractiveViewer(
              maxScale: 8,
              child: Image.asset('assets/images/baybayin_chart.jpg'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmReset(BuildContext context) async {
    final confirmed = await showCupertinoDialog<bool>(
      context: context,
      builder: (context) => CupertinoAlertDialog(
        title: const Text('Reset settings?'),
        content: const Text('All settings go back to their defaults.'),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (confirmed == true) await AppSettings.instance.resetToDefaults();
  }
}

class _EmptyLicensesPage extends StatelessWidget {
  const _EmptyLicensesPage();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Open-source licenses'),
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.brown,
        elevation: 0,
      ),
      extendBodyBehindAppBar: true,
      body: const GlassBackground(
        child: Center(
          child: Text(
            'No licenses to show yet.',
            style: TextStyle(color: Colors.black54),
          ),
        ),
      ),
    );
  }
}

/// A titled group of rows on one glass card, rows split by hairlines.
class _Section extends StatelessWidget {
  final String? title;
  final List<Widget> children;

  const _Section({this.title, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
              child: Text(
                title!.toUpperCase(),
                style: const TextStyle(
                  fontSize: 12,
                  letterSpacing: 0.6,
                  fontWeight: FontWeight.w600,
                  color: Colors.black45,
                ),
              ),
            ),
          GlassContainer(
            borderRadius: const BorderRadius.all(Radius.circular(18)),
            child: Column(
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      thickness: 0.5,
                      indent: 58,
                      color: Colors.black.withValues(alpha: 0.12),
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One settings row: colored icon badge, title (+ optional subtitle),
/// optional trailing widget, and an optional full-width control below.
class _Tile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final Color? titleColor;
  final String? subtitle;
  final Widget? trailing;
  final Widget? below;
  final bool showChevron;
  final VoidCallback? onTap;

  const _Tile({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.titleColor,
    this.subtitle,
    this.trailing,
    this.below,
    this.showChevron = false,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: iconColor,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(icon, color: Colors.white, size: 18),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                          color: titleColor ?? Colors.black87,
                        ),
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.black54,
                          ),
                        ),
                    ],
                  ),
                ),
                if (trailing != null) ...[const SizedBox(width: 8), trailing!],
                if (showChevron)
                  const Icon(Icons.chevron_right, color: Colors.black38),
              ],
            ),
            if (below != null) ...[
              const SizedBox(height: 10),
              Padding(padding: const EdgeInsets.only(left: 44), child: below),
            ],
          ],
        ),
      ),
    );
  }
}

class _SwitchTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.icon,
    required this.iconColor,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _Tile(
      icon: icon,
      iconColor: iconColor,
      title: title,
      subtitle: subtitle,
      onTap: () => onChanged(!value),
      trailing: CupertinoSwitch(
        value: value,
        activeTrackColor: Colors.brown,
        onChanged: onChanged,
      ),
    );
  }
}

/// The app's liquid glass selector on a small dark track, sized for a
/// settings row.
class _SmallSelector extends StatelessWidget {
  final List<String> labels;
  final int selectedIndex;
  final ValueChanged<int> onChanged;

  const _SmallSelector({
    required this.labels,
    required this.selectedIndex,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    // Plain dark track (no second blur): it already sits on a glass card.
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(11),
      ),
      child: LiquidGlassSelector(
        count: labels.length,
        selectedIndex: selectedIndex,
        height: 30,
        pillRadius: const BorderRadius.all(Radius.circular(8)),
        onChanged: onChanged,
        itemBuilder: (context, i, selectedness) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            labels[i],
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Color.lerp(Colors.white70, Colors.black87, selectedness),
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
          ),
        ),
      ),
    );
  }
}
