import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_language.dart';
import 'legal_screen.dart';
import '../services/app_settings.dart';
import '../services/haptics.dart';
import '../services/tagalog_to_baybayin_local_translator.dart';
import '../widgets/dayaw_style.dart';
import '../widgets/glass.dart';
import 'dayaw_landing_screen.dart';

/// First-launch introduction: four swipeable pages over drifting warm
/// color blobs, each built around a frosted glass card.
///
///   1. "Dayaw" writes itself in cursive, like a pen.
///   2. Scanning: Baybayin letters flip into their Tagalog readings.
///   3. Writing: Tagalog types itself out and turns into Baybayin.
///   4. Works offline - then "Get Started".
///
/// Also reachable from Settings ([fromSettings]), in which case finishing
/// just goes back instead of opening the app's home.
class IntroScreen extends StatefulWidget {
  final bool fromSettings;

  const IntroScreen({super.key, this.fromSettings = false});

  @override
  State<IntroScreen> createState() => _IntroScreenState();
}

class _IntroScreenState extends State<IntroScreen>
    with TickerProviderStateMixin {
  static const _pageCount = 4;
  static Color get _yellow => DayawColors.sun;
  static Color get _amber => DayawColors.amber;
  static Color get _deepBrown => DayawColors.text;

  final PageController _pages = PageController();
  double _page = 0;

  /// Slow loop for the background sun.
  late final AnimationController _drift = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 14),
  )..repeat();

  /// Page 1: the handwriting, then the subtitle.
  late final AnimationController _write = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3400),
  );

  /// Pages 2-3: repeating demo loops.
  late final AnimationController _demo = AnimationController(
    vsync: this,
    duration: const Duration(seconds: 6),
  )..repeat();

  @override
  void initState() {
    super.initState();
    _pages.addListener(() => setState(() => _page = _pages.page ?? 0));
    // Small pause so the screen settles before the pen starts.
    Future.delayed(const Duration(milliseconds: 350), () {
      if (mounted) _write.forward();
    });
  }

  @override
  void dispose() {
    _pages.dispose();
    _drift.dispose();
    _write.dispose();
    _demo.dispose();
    super.dispose();
  }

  void _finish() {
    AppSettings.instance.hasSeenIntro = true;
    if (widget.fromSettings) {
      Navigator.of(context).pop();
      return;
    }
    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        transitionDuration: const Duration(milliseconds: 600),
        pageBuilder: (_, _, _) => const DayawLandingScreen(),
        transitionsBuilder: (_, animation, _, child) => FadeTransition(
          opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
          child: child,
        ),
      ),
    );
  }

  void _next() {
    Haptics.light();
    if (_page.round() >= _pageCount - 1) {
      _finish();
    } else {
      _pages.nextPage(
        duration: const Duration(milliseconds: 520),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page.round() == _pageCount - 1;
    return Scaffold(
      backgroundColor: DayawColors.bg,
      body: Stack(
        children: [
          Positioned.fill(child: _buildDriftingBackground()),
          SafeArea(
            child: Column(
              children: [
                // Skip - hidden on the last page, which has its own button.
                SizedBox(
                  height: 48,
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: AnimatedOpacity(
                      opacity: isLast ? 0 : 1,
                      duration: const Duration(milliseconds: 250),
                      child: TextButton(
                        onPressed: isLast ? null : _finish,
                        child: Text(
                          context.tr('Skip', 'Laktawan'),
                          style: TextStyle(
                            color: _deepBrown,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(
                  child: PageView(
                    controller: _pages,
                    children: [
                      _parallax(0, _buildWelcomePage()),
                      _parallax(1, _buildScanPage()),
                      _parallax(2, _buildWritePage()),
                      _parallax(3, _buildOfflinePage()),
                    ],
                  ),
                ),
                // Last page: what tapping "Get Started" agrees to.
                AnimatedOpacity(
                  opacity: isLast ? 1 : 0,
                  duration: const Duration(milliseconds: 250),
                  child: IgnorePointer(
                    ignoring: !isLast,
                    child: _buildLegalNotice(),
                  ),
                ),
                _buildBottomBar(isLast),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Pages fade and shrink slightly as they slide away.
  Widget _parallax(int index, Widget child) {
    final distance = (_page - index).abs().clamp(0.0, 1.0);
    return Opacity(
      opacity: 1 - 0.6 * distance,
      child: Transform.scale(scale: 1 - 0.08 * distance, child: child),
    );
  }

  // ---------------------------------------------------------------------
  // Background
  // ---------------------------------------------------------------------

  /// The plain ground behind the pages.
  Widget _buildDriftingBackground() {
    DayawTheme.of(context);
    return ColoredBox(color: DayawColors.bg);
  }

  // ---------------------------------------------------------------------
  // Shared page layout
  // ---------------------------------------------------------------------

  Widget _pageLayout({
    required Widget hero,
    required String title,
    required String body,
  }) {
    // Centered when there's room; scrolls instead of overflowing on
    // short screens.
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              hero,
              const SizedBox(height: 36),
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: _deepBrown,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                body,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  color: DayawColors.textMuted,
                  height: 1.45,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Page 1 - "Dayaw" handwritten
  // ---------------------------------------------------------------------

  Widget _buildWelcomePage() {
    return Center(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: GlassContainer(
            borderRadius: const BorderRadius.all(Radius.circular(36)),
            padding: const EdgeInsets.fromLTRB(28, 40, 28, 36),
            tint: const Color(0x80FFFFFF),
            child: AnimatedBuilder(
              animation: _write,
              builder: (context, _) {
                // First 70%: the pen writes. Last 30%: the rest fades in.
                final penRaw = (_write.value / 0.7).clamp(0.0, 1.0);
                final afterglow = ((_write.value - 0.7) / 0.3).clamp(0.0, 1.0);
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Scales down on narrow phones instead of wrapping.
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: _HandwrittenWord(
                        text: 'Dayaw',
                        progress: _typewriterProgress(penRaw, letters: 5),
                        penVisible: penRaw > 0 && penRaw < 1,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Flourish underline, drawn left to right after the word.
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FractionallySizedBox(
                        widthFactor: Curves.easeOutCubic.transform(afterglow),
                        child: Container(
                          height: 3,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(2),
                            color: _yellow,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Opacity(
                      opacity: afterglow,
                      child: Transform.translate(
                        offset: Offset(0, 12 * (1 - afterglow)),
                        child: Column(
                          children: [
                            Text(
                              context.tr(
                                'Pride in our own script.',
                                'Dangal sa sarili nating panitik.',
                              ),
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                                color: _deepBrown,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              context.tr(
                                'Read and write Baybayin, anywhere.',
                                'Magbasa at magsulat ng Baybayin, saanman.',
                              ),
                              style: TextStyle(
                                fontSize: 13,
                                color: DayawColors.textMuted,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  /// Typewriter rhythm for a continuous pen: the reveal moves letter by
  /// letter, each letter written with a quick ease-out, then a tiny pause.
  double _typewriterProgress(double raw, {required int letters}) {
    if (raw >= 1) return 1;
    final scaled = raw * letters;
    final index = scaled.floor();
    final within = scaled - index;
    final eased = Curves.easeOutCubic.transform((within / 0.8).clamp(0, 1));
    return (index + eased) / letters;
  }

  // ---------------------------------------------------------------------
  // Page 2 - scanning demo
  // ---------------------------------------------------------------------

  static const _scanPairs = [
    ('ᜊ', 'ba'),
    ('ᜌ᜔', 'y'),
    ('ᜃ', 'ka'),
    ('ᜎ', 'la'),
    ('ᜋ', 'ma'),
    ('ᜆ', 'ta'),
  ];

  Widget _buildScanPage() {
    return _pageLayout(
      hero: AnimatedBuilder(
        animation: _demo,
        builder: (context, _) {
          final cycle = _demo.value * _scanPairs.length;
          final index = cycle.floor() % _scanPairs.length;
          final within = cycle - cycle.floor();
          // First half of each beat shows Baybayin, second half Tagalog.
          final showLatin = within > 0.5;
          final (glyph, latin) = _scanPairs[index];
          return GlassContainer(
            height: 220,
            borderRadius: const BorderRadius.all(Radius.circular(32)),
            child: Stack(
              alignment: Alignment.center,
              children: [
                // Viewfinder corners.
                for (final corner in [
                  Alignment.topLeft,
                  Alignment.topRight,
                  Alignment.bottomLeft,
                  Alignment.bottomRight,
                ])
                  Align(
                    alignment: corner,
                    child: Padding(
                      padding: const EdgeInsets.all(22),
                      child: _ViewfinderCorner(corner: corner),
                    ),
                  ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 350),
                  transitionBuilder: (child, animation) => ScaleTransition(
                    scale: CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOutBack,
                    ),
                    child: FadeTransition(opacity: animation, child: child),
                  ),
                  child: Text(
                    showLatin ? latin : glyph,
                    key: ValueKey('$index$showLatin'),
                    style: TextStyle(
                      fontFamily: showLatin ? null : 'BaybayinCustom',
                      fontSize: showLatin ? 64 : 84,
                      fontWeight: showLatin ? FontWeight.w900 : null,
                      color: showLatin ? _amber : _deepBrown,
                    ),
                  ),
                ),
                // Scan line sweeping while the Baybayin is shown.
                if (!showLatin)
                  Align(
                    alignment: Alignment(0, -0.8 + 3.2 * within),
                    child: Container(
                      height: 3,
                      margin: const EdgeInsets.symmetric(horizontal: 30),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            _yellow.withValues(alpha: 0),
                            _yellow,
                            _yellow.withValues(alpha: 0),
                          ],
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: _yellow.withValues(alpha: 0.5),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
      title: context.tr(
        'Scan handwritten Baybayin',
        'I-scan ang sulat-kamay na Baybayin',
      ),
      body: context.tr(
        'Point your camera at Baybayin writing and read it in Latin letters, '
            'one character at a time.',
        'Itutok ang kamera sa sulat na Baybayin at basahin ito sa titik '
            'Latin, isa-isang karakter.',
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Page 3 - writing demo
  // ---------------------------------------------------------------------

  static const _demoPhrase = 'mahal kita';
  final _translator = TagalogToBaybayinLocalTranslator();

  Widget _buildWritePage() {
    return _pageLayout(
      hero: AnimatedBuilder(
        animation: _demo,
        builder: (context, _) {
          // Type during the first 60% of the loop, hold, then restart.
          final typed = (_demo.value / 0.6).clamp(0.0, 1.0);
          final count = (typed * _demoPhrase.length).round();
          final text = _demoPhrase.substring(0, count);
          final baybayin = _translator.translate(text)['translated_text'] ?? '';
          final caretOn = (_demo.value * 12).floor().isEven;
          return GlassContainer(
            borderRadius: const BorderRadius.all(Radius.circular(32)),
            padding: const EdgeInsets.all(22),
            child: SizedBox(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'FILIPINO',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w800,
                      color: DayawColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 6),
                  // One line that shrinks to fit, so the card never grows.
                  _oneLine(
                    Text.rich(
                      TextSpan(
                        text: text,
                        children: [
                          TextSpan(
                            text: '|',
                            style: TextStyle(
                              color: caretOn ? _amber : Colors.transparent,
                            ),
                          ),
                        ],
                      ),
                      maxLines: 1,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        color: _deepBrown,
                      ),
                    ),
                    height: 32,
                  ),
                  const SizedBox(height: 14),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 1.5,
                          color: _amber.withValues(alpha: 0.5),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(
                          Icons.south_rounded,
                          color: _amber,
                          size: 20,
                        ),
                      ),
                      Expanded(
                        child: Container(
                          height: 1.5,
                          color: _amber.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'BAYBAYIN',
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w800,
                      color: DayawColors.textMuted,
                    ),
                  ),
                  const SizedBox(height: 4),
                  _oneLine(
                    Text(
                      baybayin.toString(),
                      maxLines: 1,
                      style: TextStyle(
                        fontFamily: 'BaybayinCustom',
                        fontSize: 30,
                        color: _amber,
                        letterSpacing: 3,
                      ),
                    ),
                    height: 46,
                  ),
                ],
              ),
            ),
          );
        },
      ),
      title: context.tr(
        'Turn Filipino into Baybayin',
        'Gawing Baybayin ang Filipino',
      ),
      body: context.tr(
        'Type anything in Filipino and watch it become Baybayin, '
            'syllable by syllable.',
        'Mag-type ng kahit ano sa Filipino at panoorin itong maging '
            'Baybayin, pantig por pantig.',
      ),
    );
  }

  /// Fixed-height single line that shrinks its text to fit the width.
  Widget _oneLine(Widget text, {required double height}) {
    return SizedBox(
      height: height,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: text,
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Page 4 - offline
  // ---------------------------------------------------------------------

  Widget _buildOfflinePage() {
    return _pageLayout(
      hero: AnimatedBuilder(
        animation: _drift,
        builder: (context, _) {
          final pulse = 0.5 - 0.5 * math.cos(_drift.value * 2 * math.pi * 4);
          return GlassContainer(
            height: 220,
            borderRadius: const BorderRadius.all(Radius.circular(32)),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _featureBadge(
                  Icons.wifi_off_rounded,
                  context.tr('Offline', 'Offline'),
                  pulse,
                ),
                _featureBadge(
                  Icons.lock_outline_rounded,
                  context.tr('Private', 'Pribado'),
                  pulse,
                ),
                _featureBadge(
                  Icons.bolt_rounded,
                  context.tr('Fast', 'Mabilis'),
                  pulse,
                ),
              ],
            ),
          );
        },
      ),
      title: context.tr(
        'No internet? No problem.',
        'Walang internet? Walang problema.',
      ),
      body: context.tr(
        'Everything runs right on your phone. Your photos and text never '
            'leave it.',
        'Lahat ay tumatakbo mismo sa iyong phone. Hindi kailanman lumalabas '
            'dito ang iyong mga larawan at teksto.',
      ),
    );
  }

  Widget _featureBadge(IconData icon, String label, double pulse) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 64,
          height: 64,
          // Raised yellow disc whose shadows breathe with the pulse.
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _yellow,
            boxShadow: neuShadows(depth: 0.5 + 0.3 * pulse),
          ),
          child: Icon(icon, color: DayawColors.onSun, size: 30),
        ),
        const SizedBox(height: 10),
        Text(
          label,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            color: _deepBrown,
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------
  // Bottom bar - page dots + next / get started
  // ---------------------------------------------------------------------

  /// "By continuing, you agree to the Terms of Use and Privacy & Data",
  /// with both names tappable.
  Widget _buildLegalNotice() {
    Widget link(LegalDocument document) => GestureDetector(
      onTap: () => LegalScreen.open(context, document),
      child: Text(
        document.title(context),
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w800,
          color: _deepBrown,
          decoration: TextDecoration.underline,
          decorationColor: _amber,
        ),
      ),
    );
    final plain = TextStyle(fontSize: 12.5, color: DayawColors.textMuted);
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 0),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: [
          Text(
            context.tr(
              'By continuing, you agree to the',
              'Sa pagpapatuloy, sumasang-ayon ka sa',
            ),
            style: plain,
          ),
          link(LegalDocument.terms),
          Text(context.tr('and', 'at'), style: plain),
          link(LegalDocument.privacy),
        ],
      ),
    );
  }

  Widget _buildBottomBar(bool isLast) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
      child: SizedBox(
        height: 58,
        child: Row(
          children: [
            // Dots: the active one stretches into a yellow pill, and it
            // follows the swipe continuously.
            Row(
              children: [
                for (var i = 0; i < _pageCount; i++)
                  Builder(
                    builder: (context) {
                      final closeness = (1 - (_page - i).abs()).clamp(0.0, 1.0);
                      return Container(
                        margin: const EdgeInsets.only(right: 6),
                        width: 8 + 18 * closeness,
                        height: 8,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(4),
                          color: Color.lerp(
                            DayawColors.line,
                            _yellow,
                            closeness,
                          ),
                        ),
                      );
                    },
                  ),
              ],
            ),
            const Spacer(),
            // Circle "next" button that widens into "Get Started".
            AnimatedContainer(
              duration: const Duration(milliseconds: 380),
              curve: Curves.easeOutCubic,
              width: isLast ? 180 : 58,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(29),
                color: _yellow,
                boxShadow: neuShadows(depth: 0.8),
              ),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(29),
                  onTap: _next,
                  child: ClipRect(
                    child: Center(
                      child: isLast
                          ? Text(
                              context.tr('Get Started', 'Magsimula'),
                              maxLines: 1,
                              softWrap: false,
                              overflow: TextOverflow.clip,
                              style: const TextStyle(
                                color: DayawColors.onSun,
                                fontSize: 17,
                                fontWeight: FontWeight.w900,
                              ),
                            )
                          : const Icon(
                              Icons.arrow_forward_rounded,
                              color: DayawColors.onSun,
                            ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A word in the cursive font, revealed left to right like it's being
/// written, with a glowing pen nib riding the leading edge.
class _HandwrittenWord extends StatelessWidget {
  final String text;
  final double progress;
  final bool penVisible;

  const _HandwrittenWord({
    required this.text,
    required this.progress,
    required this.penVisible,
  });

  @override
  Widget build(BuildContext context) {
    DayawTheme.of(context);
    final style = TextStyle(
      fontFamily: 'GreatVibes',
      fontSize: 96,
      height: 1.15,
      color: DayawColors.text,
    );
    return Stack(
      clipBehavior: Clip.none,
      children: [
        ClipRect(
          clipper: _RevealClipper(progress),
          child: Text(text, style: style),
        ),
        if (penVisible)
          Positioned.fill(
            child: Align(
              // Rides the reveal edge, bobbing up and down like a hand.
              alignment: Alignment(
                -1 + 2 * progress,
                0.15 + 0.35 * math.sin(progress * math.pi * 10),
              ),
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: DayawColors.sun,
                  boxShadow: [
                    BoxShadow(
                      color: DayawColors.sun.withValues(alpha: 0.6),
                      blurRadius: 12,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _RevealClipper extends CustomClipper<Rect> {
  final double progress;

  _RevealClipper(this.progress);

  @override
  Rect getClip(Size size) =>
      // A little extra room above/below so tall cursive loops aren't cut.
      Rect.fromLTRB(-20, -40, size.width * progress, size.height + 40);

  @override
  bool shouldReclip(_RevealClipper oldClipper) =>
      oldClipper.progress != progress;
}

/// One L-shaped corner of a camera viewfinder.
class _ViewfinderCorner extends StatelessWidget {
  final Alignment corner;

  const _ViewfinderCorner({required this.corner});

  @override
  Widget build(BuildContext context) {
    final side = BorderSide(color: DayawColors.amber, width: 4);
    return SizedBox(
      width: 28,
      height: 28,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: corner.y < 0 ? side : BorderSide.none,
            bottom: corner.y > 0 ? side : BorderSide.none,
            left: corner.x < 0 ? side : BorderSide.none,
            right: corner.x > 0 ? side : BorderSide.none,
          ),
        ),
      ),
    );
  }
}