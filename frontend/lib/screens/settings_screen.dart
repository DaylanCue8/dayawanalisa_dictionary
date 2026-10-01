import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../services/app_language.dart';
import '../services/app_settings.dart';
import '../widgets/dayaw_style.dart';
import '../widgets/glass.dart';
import '../widgets/info_modal.dart';
import '../widgets/liquid_glass_selector.dart';
import 'intro_screen.dart';
import 'legal_screen.dart';

/// iOS-style grouped settings, each group a frosted glass card. Every
/// value is saved on the device (see [AppSettings]). Shares the
/// translator tabs' look: shimmering hero header, honey section titles
/// and one calm brown icon style.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  static const String appVersion = '1.0.0';

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  /// Drives the header shimmer (Gradient theme), same timing as the
  /// translator tabs.
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  )..repeat();

  @override
  void dispose() {
    _ambient.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = AppSettings.instance;
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
        children: [
          DayawHeroHeader(
            title: context.tr('Settings', 'Mga Setting'),
            subtitle: context.tr(
              'Make Dayaw work the way you read and write.',
              'Iayon ang Dayaw sa paraan mo ng pagbasa at pagsulat.',
            ),
            baybayin: 'ᜀᜌᜓᜐᜒᜈ᜔',
            shimmer: _ambient,
          ),
          const SizedBox(height: 20),

          _Section(
            title: context.tr('Camera', 'Kamera'),
            icon: Icons.camera_alt_outlined,
            children: [
              _Tile(
                icon: Icons.edit_outlined,
                title: context.tr('Default input', 'Default na panulat'),
                subtitle: context.tr(
                  'What the camera starts on',
                  'Unang gamit ng kamera',
                ),
                trailing: SizedBox(
                  width: 128,
                  child: _SmallSelector(
                    labels: [
                      context.tr('Marker', 'Marker'),
                      context.tr('Pen', 'Bolpen'),
                    ],
                    selectedIndex: settings.cameraInputType == 'pen' ? 1 : 0,
                    onChanged: (i) =>
                        settings.cameraInputType = i == 1 ? 'pen' : 'marker',
                  ),
                ),
              ),
              _SwitchTile(
                icon: Icons.grid_4x4,
                title: context.tr(
                  'Show grid by default',
                  'Ipakita ang grid sa simula',
                ),
                value: settings.cameraGridByDefault,
                onChanged: (v) => settings.cameraGridByDefault = v,
              ),
            ],
          ),

          _Section(
            title: context.tr('Results', 'Mga Resulta'),
            icon: Icons.grid_view_rounded,
            children: [
              _Tile(
                icon: Icons.filter_b_and_w_outlined,
                title: context.tr('Default filter', 'Default na filter'),
                below: _SmallSelector(
                  labels: [
                    context.tr('Raw', 'Orihinal'),
                    context.tr('Black and White', 'Itim at Puti'),
                    'HOG',
                  ],
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
                title: context.tr(
                  'Show bounding boxes by default',
                  'Ipakita ang mga bounding box sa simula',
                ),
                value: settings.showBoundingBoxesByDefault,
                onChanged: (v) => settings.showBoundingBoxesByDefault = v,
              ),
              _Tile(
                icon: Icons.tune,
                title: context.tr(
                  'Minimum confidence',
                  'Pinakamababang kumpiyansa',
                ),
                subtitle: context.tr(
                  'Hide characters the model is less sure about',
                  'Itago ang mga karakter na hindi gaanong sigurado ang model',
                ),
                trailing: Text(
                  '${settings.minConfidence.round()}%',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: DayawColors.deepBrown,
                  ),
                ),
                below: SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: DayawColors.deepBrown,
                    inactiveTrackColor: DayawColors.yellow.withValues(
                      alpha: 0.45,
                    ),
                    thumbColor: Colors.white,
                    overlayColor: DayawColors.amber.withValues(alpha: 0.15),
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
            title: context.tr('Experience', 'Karanasan'),
            icon: Icons.auto_awesome,
            children: [
              _SwitchTile(
                icon: Icons.vibration,
                title: context.tr('Haptic feedback', 'Pag-vibrate'),
                subtitle: context.tr(
                  'Vibrate on taps, tabs, filters and copying',
                  'Mag-vibrate sa pag-tap, tab, filter at pagkopya',
                ),
                value: settings.hapticsEnabled,
                onChanged: (v) => settings.hapticsEnabled = v,
              ),
              _SwitchTile(
                icon: Icons.blur_off,
                title: context.tr(
                  'Reduce transparency',
                  'Bawasan ang transparency',
                ),
                subtitle: context.tr(
                  'Solid panels instead of frosted glass',
                  'Solidong panel sa halip na malabong salamin',
                ),
                value: settings.reduceTransparency,
                onChanged: (v) => settings.reduceTransparency = v,
              ),
            ],
          ),

          _Section(
            title: context.tr('About', 'Tungkol'),
            icon: Icons.info_outline,
            children: [
              _Tile(
                icon: Icons.menu_book_outlined,
                title: context.tr('About Dayaw', 'Tungkol sa Dayaw'),
                subtitle: context.tr(
                  'The project and how to write for Baybayin',
                  'Ang proyekto at kung paano sumulat para sa Baybayin',
                ),
                showChevron: true,
                onTap: () => showModalBottomSheet(
                  context: context,
                  isScrollControlled: true,
                  backgroundColor: Colors.transparent,
                  builder: (context) => const InfoModal(),
                ),
              ),
              for (final document in LegalDocument.values)
                _Tile(
                  icon: document.icon,
                  title: document.title(context),
                  showChevron: true,
                  onTap: () => LegalScreen.open(context, document),
                ),
              _Tile(
                icon: Icons.auto_awesome,
                title: context.tr('Show introduction', 'Ipakita ang panimula'),
                showChevron: true,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const IntroScreen(fromSettings: true),
                  ),
                ),
              ),
              _Tile(
                icon: Icons.table_chart_outlined,
                title: context.tr('Baybayin chart', 'Tsart ng Baybayin'),
                showChevron: true,
                onTap: () => _showChart(context),
              ),
              _Tile(
                icon: Icons.description_outlined,
                title: context.tr(
                  'Open-source licenses',
                  'Mga open-source na lisensya',
                ),
                showChevron: true,
                // Left empty for now; swap back to showLicensePage(...) to
                // list the packages' licenses.
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const _EmptyLicensesPage(),
                  ),
                ),
              ),
              _Tile(
                icon: Icons.verified_outlined,
                title: context.tr('Version', 'Bersyon'),
                trailing: const Text(
                  SettingsScreen.appVersion,
                  style: TextStyle(color: Colors.black54),
                ),
              ),
            ],
          ),

          _Section(
            children: [
              _Tile(
                icon: Icons.restart_alt,
                title: context.tr('Reset settings', 'I-reset ang mga setting'),
                destructive: true,
                onTap: () => _confirmReset(context),
              ),
            ],
          ),

          const SizedBox(height: 4),
          Center(
            child: Text(
              context.tr(
                '© 2026 DAYAW. All rights reserved.',
                '© 2026 DAYAW. Nakalaan ang lahat ng karapatan.',
              ),
              style: const TextStyle(fontSize: 11, color: Colors.grey),
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
        backgroundColor: DayawColors.cream,
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
              style: TextButton.styleFrom(
                foregroundColor: DayawColors.deepBrown,
              ),
              child: Text(context.tr('Close', 'Isara')),
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
        title: Text(context.tr('Reset settings?', 'I-reset ang mga setting?')),
        content: Text(
          context.tr(
            'All settings go back to their defaults.',
            'Babalik sa default ang lahat ng setting.',
          ),
        ),
        actions: [
          CupertinoDialogAction(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(context.tr('Cancel', 'Kanselahin')),
          ),
          CupertinoDialogAction(
            isDestructiveAction: true,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(context.tr('Reset', 'I-reset')),
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
        title: Text(
          context.tr('Open-source licenses', 'Mga open-source na lisensya'),
        ),
        backgroundColor: Colors.transparent,
        foregroundColor: DayawColors.deepBrown,
        elevation: 0,
      ),
      extendBodyBehindAppBar: true,
      body: GlassBackground(
        child: Center(
          child: Text(
            context.tr(
              'No licenses to show yet.',
              'Wala pang lisensyang maipapakita.',
            ),
            style: const TextStyle(color: Colors.black54),
          ),
        ),
      ),
    );
  }
}

/// A titled group of rows on one glass card, rows split by hairlines.
class _Section extends StatelessWidget {
  final String? title;
  final IconData? icon;
  final List<Widget> children;

  const _Section({this.title, this.icon, required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null) ...[
            DayawSectionTitle(title!, icon ?? Icons.circle_outlined),
            const SizedBox(height: 10),
          ],
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
                      color: DayawColors.deepBrown.withValues(alpha: 0.12),
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

/// One settings row: brown icon badge, title (+ optional subtitle),
/// optional trailing widget, and an optional full-width control below.
/// [destructive] rows (e.g. reset) use the muted brick color instead.
class _Tile extends StatelessWidget {
  final IconData icon;
  final String title;
  final bool destructive;
  final String? subtitle;
  final Widget? trailing;
  final Widget? below;
  final bool showChevron;
  final VoidCallback? onTap;

  const _Tile({
    required this.icon,
    required this.title,
    this.destructive = false,
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
                    color: destructive
                        ? DayawColors.brick
                        : DayawColors.deepBrown,
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(
                    icon,
                    color: destructive ? Colors.white : DayawColors.gold,
                    size: 17,
                  ),
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
                          fontWeight: FontWeight.w600,
                          color: destructive
                              ? DayawColors.brick
                              : DayawColors.deepBrown,
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
                  Icon(
                    Icons.chevron_right,
                    color: DayawColors.deepBrown.withValues(alpha: 0.4),
                  ),
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
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _SwitchTile({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return _Tile(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: () => onChanged(!value),
      trailing: CupertinoSwitch(
        value: value,
        activeTrackColor: DayawColors.deepBrown,
        onChanged: onChanged,
      ),
    );
  }
}

/// The app's liquid glass selector on a small brown track, sized for a
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
    // Plain brown track (no second blur): it already sits on a glass card.
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: DayawColors.deepBrown.withValues(alpha: 0.8),
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
