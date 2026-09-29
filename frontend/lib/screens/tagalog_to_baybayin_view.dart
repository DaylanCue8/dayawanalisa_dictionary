import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/api_service.dart';
import '../services/app_language.dart';
import '../services/app_settings.dart';
import '../services/recognition_outcome.dart';
import '../services/tagalog_to_baybayin_local_translator.dart';
import '../widgets/dayaw_style.dart';
import '../widgets/glass.dart';

/// Handles the "Filipino to Baybayin" mode (internally still keyed as
/// 'Tagalog to Baybayin' for the translator): debounced auto-translate as the
/// user types, with confidence display. Fully self-contained — owns its
/// own state, independent of the image-translation mode.
///
/// Shares the Baybayin to Latin tab's look: shimmering hero header, a
/// glowing input card, a pop-in result card with a confidence ring, a
/// syllable breakdown, writing tips and rotating Baybayin facts.
class TagalogToBaybayinView extends StatefulWidget {
  const TagalogToBaybayinView({super.key});

  @override
  State<TagalogToBaybayinView> createState() => _TagalogToBaybayinViewState();
}

class _TagalogToBaybayinViewState extends State<TagalogToBaybayinView>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  final TagalogToBaybayinLocalTranslator _translator =
      TagalogToBaybayinLocalTranslator();
  final TextEditingController _textController = TextEditingController();
  final FocusNode _inputFocus = FocusNode();

  // Debounce timer so we don't fire a request on every keystroke — waits
  // for a short pause in typing before translating automatically.
  Timer? _debounce;

  String _translatedResult = "";
  double _confidenceScore = 0.0;
  bool _isLoading = false;
  bool _hasError = false;

  /// One entry per non-empty line of input: its syllable pieces.
  List<List<({String latin, String baybayin})>> _lineBreakdown = [];

  /// One looping 0..1 clock that drives every ambient animation on this
  /// tab (glow border, shimmer, breathing), so only one ticker runs.
  late final AnimationController _ambient = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 3200),
  )..repeat();

  // "Did you know?" card: rotates to the next fact every few seconds.
  Timer? _factTimer;
  int _factIndex = 0;

  @override
  void initState() {
    super.initState();
    _inputFocus.addListener(() => setState(() {}));
    _factTimer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (mounted) {
        setState(() => _factIndex = (_factIndex + 1) % _facts.length);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _factTimer?.cancel();
    _ambient.dispose();
    _inputFocus.dispose();
    _textController.dispose();
    super.dispose();
  }

  /// Called on every keystroke. Restarts a 350ms timer each time so the
  /// actual translation only fires once typing pauses.
  void _onTextChanged(String text) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      _handleTextTranslation(text);
    });
  }

  Future<void> _handleTextTranslation(String text) async {
    if (text.trim().isEmpty) {
      setState(() {
        _translatedResult = "";
        _confidenceScore = 0.0;
        _isLoading = false;
        _hasError = false;
        _lineBreakdown = [];
      });
      return;
    }

    setState(() {
      _isLoading = true;
    });

    final response = await _apiService.uploadAndTranslateDetailed(
      null,
      'Tagalog to Baybayin',
      text: text,
    );

    if (!mounted) return;

    setState(() {
      _isLoading = false;
      if (response != null) {
        _translatedResult = response['translated_text'] ?? "";
        _confidenceScore = readNumber(response, 'confidence');
        _hasError = false;
      } else {
        _translatedResult = tr(
          'Error: Connection Failed',
          'Error: Hindi makakonekta',
        );
        _confidenceScore = 0.0;
        _hasError = true;
      }
      _lineBreakdown = [
        for (final line in text.split('\n'))
          if (line.trim().isNotEmpty)
            _translator
                .breakdown(line)
                .where((piece) => piece.latin.trim().isNotEmpty)
                .toList(),
      ].where((pieces) => pieces.isNotEmpty).toList();
    });
  }

  Color _confidenceColor(double confidence) {
    if (confidence >= 95) return const Color(0xFF5E8B5A);
    if (confidence >= 75) return const Color(0xFFC2873F);
    return const Color(0xFFB35C52);
  }

  void _clear() {
    _debounce?.cancel();
    _textController.clear();
    _handleTextTranslation("");
  }

  /// Fills the input with a sample phrase and translates it right away.
  void _useExample(String text) {
    _debounce?.cancel();
    _textController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    if (AppSettings.instance.hapticsEnabled) HapticFeedback.selectionClick();
    _handleTextTranslation(text);
  }

  void _copyResult() {
    Clipboard.setData(ClipboardData(text: _translatedResult));
    if (AppSettings.instance.hapticsEnabled) HapticFeedback.lightImpact();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(tr('Copied to clipboard', 'Nakopya na')),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // UI
  //
  // Mirrors the Baybayin to Latin tab: same palette, same single
  // ambient clock, same card language - so both directions feel like
  // one app.
  // ---------------------------------------------------------------------

  // Shared muted-honey palette (see DayawColors).
  static const Color _amber = DayawColors.amber;
  static const Color _gold = DayawColors.gold;
  static const Color _yellow = DayawColors.yellow;
  static const Color _deepBrown = DayawColors.deepBrown;

  static const List<String> _examples = [
    'Mahal kita',
    'Magandang umaga',
    'Salamat po',
    'Mabuhay',
    'Kumusta ka',
  ];

  // (icon, English, Filipino)
  static const List<(IconData, String, String)> _tips = [
    (
      Icons.record_voice_over_outlined,
      'Spell it as you say it',
      'Isulat ayon sa bigkas',
    ),
    (Icons.block, 'No C, F, J, V or Z', 'Walang C, F, J, V o Z'),
    (
      Icons.view_week_outlined,
      'One card per syllable',
      'Isang card bawat pantig',
    ),
    (Icons.keyboard_return, 'New line, new card', 'Bagong linya, bagong card'),
    (Icons.copy_rounded, 'Copy and share it', 'Kopyahin at ibahagi'),
  ];

  // (Baybayin sample, English, Filipino)
  static const List<(String, String, String)> _facts = [
    (
      'ᜊᜌ᜔ᜊᜌᜒᜈ᜔',
      'Each Baybayin character is a whole syllable: a consonant plus "a".',
      'Bawat karakter ng Baybayin ay isang buong pantig: katinig na may '
          'kasamang "a".',
    ),
    (
      'ᜅ',
      '"NG" is a single letter in Baybayin, so "nga" takes one character.',
      'Iisang titik lang ang "NG" sa Baybayin, kaya isang karakter lang '
          'ang "nga".',
    ),
    (
      'ᜋᜑᜎ᜔',
      '"Mahal" is written ma-ha-l: the last kudlit silences the final "a".',
      'Isinusulat ang "Mahal" bilang ma-ha-l: pinapatay ng huling kudlit '
          'ang "a" sa dulo.',
    ),
    (
      'ᜃ ᜃᜒ ᜃᜓ',
      'A kudlit above a letter turns its "a" into "e/i"; below, into "o/u".',
      'Ang kudlit sa itaas ng titik ay ginagawang "e/i" ang "a"; sa ibaba, '
          'nagiging "o/u".',
    ),
    (
      'ᜇ',
      'D and R share one letter in Baybayin - context tells them apart.',
      'Iisang titik ang D at R sa Baybayin - ang konteksto ang nagtatangi '
          'sa kanila.',
    ),
  ];

  /// 0..1..0 once per ambient loop - for breathing / pulsing.
  double get _breath => 0.5 - 0.5 * math.cos(2 * math.pi * _ambient.value);

  @override
  Widget build(BuildContext context) {
    return ListView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        _buildHeroHeader(),
        const SizedBox(height: 16),
        _buildInputCard(),
        const SizedBox(height: 12),
        _buildExamples(),
        const SizedBox(height: 24),
        _buildResultCard(),
        if (_lineBreakdown.isNotEmpty) ...[
          const SizedBox(height: 28),
          _sectionTitle(
            context.tr('Syllable breakdown', 'Paghahati sa pantig'),
            Icons.grid_view_rounded,
          ),
          const SizedBox(height: 12),
          _buildBreakdown(),
        ],
        const SizedBox(height: 28),
        _sectionTitle(
          context.tr(
            'Tips for clean Baybayin',
            'Mga tip para sa malinis na Baybayin',
          ),
          Icons.auto_awesome,
        ),
        const SizedBox(height: 12),
        _buildTips(),
        const SizedBox(height: 28),
        _sectionTitle(
          context.tr('Did you know?', 'Alam mo ba?'),
          Icons.lightbulb_outline,
        ),
        const SizedBox(height: 12),
        _buildFactCard(),
        const SizedBox(height: 24),
        Text(
          context.tr(
            '© 2026 DAYAW. All rights reserved.',
            '© 2026 DAYAW. Nakalaan ang lahat ng karapatan.',
          ),
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 11, color: Colors.grey),
        ),
      ],
    );
  }

  Widget _sectionTitle(String text, IconData icon) =>
      DayawSectionTitle(text, icon);

  /// Title with a gradient headline and a strip of Baybayin that gently
  /// shimmers, so the screen feels alive before anything is typed.
  Widget _buildHeroHeader() {
    return DayawHeroHeader(
      title: context.tr(
        'Write the ancient script',
        'Isulat ang sinaunang titik',
      ),
      subtitle: context.tr(
        'Type Filipino and watch it turn into Baybayin as you go.',
        'Mag-type ng Filipino at panoorin itong maging Baybayin.',
      ),
      baybayin: 'ᜉᜒᜎᜒᜉᜒᜈᜓ → ᜊᜌ᜔ᜊᜌᜒᜈ᜔',
      shimmer: _ambient,
    );
  }

  /// The text box, framed by a slowly rotating gradient glow that burns
  /// brighter while focused or translating.
  Widget _buildInputCard() {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _ambient,
        builder: (context, child) {
          final active = _isLoading || _inputFocus.hasFocus;
          final glow = active ? 0.75 + 0.25 * _breath : 0.35 + 0.35 * _breath;
          return Container(
            padding: const EdgeInsets.all(2.5),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(26),
              gradient: SweepGradient(
                transform: GradientRotation(2 * math.pi * _ambient.value),
                colors: const [
                  // Starts and ends on the same yellow so the rotating
                  // seam is invisible.
                  _yellow,
                  _amber,
                  _gold,
                  _yellow,
                  Color(0xFFB9853A),
                  _gold,
                  _yellow,
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: _yellow.withValues(alpha: 0.3 * glow),
                  blurRadius: 16 + 10 * glow,
                  spreadRadius: glow,
                ),
              ],
            ),
            child: child,
          );
        },
        child: ClipRRect(
          borderRadius: BorderRadius.circular(23.5),
          child: ColoredBox(
            color: const Color(0xFFFFFBF5),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 10, 8, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    controller: _textController,
                    focusNode: _inputFocus,
                    onChanged: _onTextChanged,
                    minLines: 4,
                    maxLines: 8,
                    keyboardType: TextInputType.multiline,
                    cursorColor: const Color(0xFFA9743A),
                    decoration: InputDecoration(
                      hintText: context.tr(
                        'Enter Filipino text here...',
                        'Ilagay ang tekstong Filipino dito...',
                      ),
                      border: InputBorder.none,
                    ),
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: _deepBrown,
                    ),
                  ),
                  ValueListenableBuilder<TextEditingValue>(
                    valueListenable: _textController,
                    builder: (context, value, _) => Row(
                      children: [
                        const Icon(
                          Icons.keyboard_alt_outlined,
                          size: 16,
                          color: Colors.black38,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          context.tr(
                            '${value.text.length} characters',
                            '${value.text.length} karakter',
                          ),
                          style: const TextStyle(
                            fontSize: 12,
                            color: Colors.black45,
                          ),
                        ),
                        const Spacer(),
                        if (value.text.isNotEmpty)
                          IconButton(
                            icon: const Icon(
                              Icons.close_rounded,
                              color: Colors.brown,
                            ),
                            onPressed: _clear,
                            tooltip: context.tr('Clear', 'Burahin'),
                          )
                        else
                          const SizedBox(height: 48),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Tappable sample phrases, for trying the translator in one tap.
  Widget _buildExamples() {
    return SizedBox(
      height: 36,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: _examples.length + 1,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          if (i == 0) {
            return Center(
              child: Text(
                context.tr('Try:', 'Subukan:'),
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Colors.black54,
                ),
              ),
            );
          }
          final example = _examples[i - 1];
          return Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(20),
              onTap: () => _useExample(example),
              child: Ink(
                padding: const EdgeInsets.symmetric(horizontal: 14),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      _yellow.withValues(alpha: 0.55),
                      _gold.withValues(alpha: 0.35),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _amber.withValues(alpha: 0.5)),
                ),
                child: Center(
                  child: Text(
                    example,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: _deepBrown,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// Placeholder / error / translation, depending on state. The
  /// translation pops in with a confidence ring, stats and a copy button.
  Widget _buildResultCard() {
    if (_isLoading && _translatedResult.isEmpty) {
      return _buildWaitingCard();
    }

    final hasResult = _translatedResult.isNotEmpty && !_hasError;
    if (!hasResult) {
      return _hasError
          ? GlassContainer(
              padding: const EdgeInsets.all(18),
              child: Row(
                children: [
                  const Icon(Icons.wifi_off_rounded, color: Color(0xFFB35C52)),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _translatedResult,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Colors.black87,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : _buildWaitingCard();
    }

    final color = _confidenceColor(_confidenceScore);
    final syllables = _lineBreakdown.fold<int>(0, (n, l) => n + l.length);
    final words = _textController.text
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty)
        .length;

    return TweenAnimationBuilder<double>(
      // Pops in with a little rise + fade the first time a result lands;
      // later edits just update the text in place.
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 520),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, 24 * (1 - t)),
          child: child,
        ),
      ),
      child: GlassContainer(
        padding: const EdgeInsets.all(18),
        // Lightly honey-tinted glass for the result card.
        tint: const Color(0xA6FFF4B8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [_gold, _yellow, _amber],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    boxShadow: const [
                      BoxShadow(color: Color(0x33D9A441), blurRadius: 8),
                    ],
                  ),
                  child: Text(
                    context.tr('IN BAYBAYIN', 'SA BAYBAYIN'),
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1,
                      color: Colors.black87,
                    ),
                  ),
                ),
                if (_isLoading) ...[
                  const SizedBox(width: 10),
                  const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.brown,
                    ),
                  ),
                ],
                const Spacer(),
                if (_confidenceScore > 0)
                  _confidenceRing(_confidenceScore, color),
              ],
            ),
            const SizedBox(height: 12),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: SelectableText(
                _translatedResult,
                key: ValueKey(_translatedResult),
                style: const TextStyle(
                  fontFamily: 'BaybayinCustom',
                  fontSize: 32,
                  color: _deepBrown,
                  height: 1.5,
                  letterSpacing: 3.0,
                ),
              ),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _statChip(
                  Icons.view_week_outlined,
                  context.tr('$syllables syllables', '$syllables pantig'),
                ),
                _statChip(
                  Icons.short_text,
                  context.tr(
                    '$words ${words == 1 ? 'word' : 'words'}',
                    '$words salita',
                  ),
                ),
                _statChip(
                  Icons.format_list_numbered,
                  context.tr(
                    '${_lineBreakdown.length} '
                        '${_lineBreakdown.length == 1 ? 'line' : 'lines'}',
                    '${_lineBreakdown.length} linya',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _copyResult,
                style: FilledButton.styleFrom(
                  backgroundColor: _deepBrown,
                  foregroundColor: _yellow,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(
                  context.tr('Copy Baybayin', 'Kopyahin ang Baybayin'),
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Empty state: a breathing quill and a line of placeholder glyphs,
  /// or "Writing..." dots while the first translation is on its way.
  Widget _buildWaitingCard() {
    return GlassContainer(
      padding: const EdgeInsets.all(18),
      child: AnimatedBuilder(
        animation: _ambient,
        builder: (context, _) => Row(
          children: [
            Transform.scale(
              scale: 1 + 0.08 * _breath,
              child: Container(
                width: 52,
                height: 52,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [_gold, _yellow, _amber],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x44D9A441),
                      blurRadius: 16,
                      offset: Offset(0, 6),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.draw_outlined,
                  color: _deepBrown,
                  size: 26,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isLoading
                        ? '${context.tr('Writing', 'Isinusulat')}'
                              '${'.' * (1 + (_ambient.value * 3).floor() % 3)}'
                        : context.tr(
                            'Your Baybayin will appear here',
                            'Dito lalabas ang iyong Baybayin',
                          ),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: _deepBrown.withValues(alpha: 0.6 + 0.4 * _breath),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    context.tr(
                      'Start typing, or tap an example above.',
                      'Magsimulang mag-type, o pumili ng halimbawa sa itaas.',
                    ),
                    style: const TextStyle(
                      fontSize: 12.5,
                      color: Colors.black54,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Circular gauge that fills up to the confidence when it appears.
  Widget _confidenceRing(double confidence, Color color) {
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: confidence / 100),
      duration: const Duration(milliseconds: 900),
      curve: Curves.easeOutCubic,
      builder: (context, value, _) => SizedBox(
        width: 54,
        height: 54,
        child: Stack(
          alignment: Alignment.center,
          children: [
            SizedBox.expand(
              child: CircularProgressIndicator(
                value: value,
                strokeWidth: 5,
                strokeCap: StrokeCap.round,
                color: color,
                backgroundColor: color.withValues(alpha: 0.15),
              ),
            ),
            Text(
              '${(value * 100).round()}%',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w900,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statChip(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _yellow.withValues(alpha: 0.55),
            _gold.withValues(alpha: 0.35),
          ],
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _amber.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: Colors.brown),
          const SizedBox(width: 5),
          Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: _deepBrown,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBreakdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < _lineBreakdown.length; i++)
          _buildLineSection(i + 1, _lineBreakdown[i]),
      ],
    );
  }

  /// One glass card per line of input: a gradient line badge, then a
  /// sideways-scrolling row of syllable cards.
  Widget _buildLineSection(
    int lineNumber,
    List<({String latin, String baybayin})> pieces,
  ) {
    return GlassContainer(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(12),
      borderRadius: const BorderRadius.all(Radius.circular(18)),
      child: Row(
        children: [
          Container(
            width: 44,
            padding: const EdgeInsets.symmetric(vertical: 8),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [_deepBrown, Color(0xFF6D4C41)],
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$lineNumber',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: _gold,
                    height: 1,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  context.tr('LINE', 'LINYA'),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                    color: Colors.white.withValues(alpha: 0.8),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              clipBehavior: Clip.none,
              child: Row(
                children: [
                  for (var i = 0; i < pieces.length; i++)
                    _buildPiece(pieces[i], i),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Baybayin glyph over its Latin syllable. Cards pop in one after
  /// another so the breakdown "writes itself" left to right.
  Widget _buildPiece(({String latin, String baybayin}) piece, int index) {
    final unsupported = piece.baybayin.isEmpty;
    return TweenAnimationBuilder<double>(
      key: ValueKey('${piece.latin}-$index'),
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 320 + 60 * math.min(index, 8)),
      curve: Curves.easeOutBack,
      builder: (context, t, child) => Opacity(
        opacity: t.clamp(0.0, 1.0),
        child: Transform.scale(scale: 0.7 + 0.3 * t, child: child),
      ),
      child: Container(
        margin: const EdgeInsets.only(right: 8),
        width: 64,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: unsupported
                ? [const Color(0xFFF8ECE8), const Color(0xFFF1DDD6)]
                : [
                    Colors.white.withValues(alpha: 0.95),
                    _yellow.withValues(alpha: 0.35),
                  ],
          ),
          border: Border.all(
            color: unsupported
                ? const Color(0xFFD4A197)
                : _amber.withValues(alpha: 0.6),
          ),
          boxShadow: const [
            BoxShadow(
              color: Color(0x22D9A441),
              blurRadius: 8,
              offset: Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: 40,
              child: Center(
                child: Text(
                  // Letters Baybayin has no glyph for (c, f, j, ...) come
                  // back empty; show "?" so the card isn't blank.
                  unsupported ? '?' : piece.baybayin,
                  style: TextStyle(
                    fontFamily: unsupported ? null : 'BaybayinCustom',
                    fontSize: unsupported ? 24 : 28,
                    fontWeight: unsupported ? FontWeight.w900 : null,
                    color: unsupported ? const Color(0xFFB35C52) : _deepBrown,
                  ),
                ),
              ),
            ),
            Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              width: 24,
              height: 2,
              decoration: BoxDecoration(
                color: unsupported
                    ? const Color(0xFFD4A197)
                    : _amber.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            Text(
              piece.latin,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w800,
                color: Colors.brown,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Sideways-scrolling row of colorful tip cards.
  Widget _buildTips() {
    return SizedBox(
      height: 96,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: _tips.length,
        separatorBuilder: (_, _) => const SizedBox(width: 10),
        itemBuilder: (context, i) {
          final (icon, en, fil) = _tips[i];
          final label = context.tr(en, fil);
          return Container(
            width: 112,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(18),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                // One quiet sand wash for every tip, so the row stays calm.
                colors: [
                  Colors.white.withValues(alpha: 0.7),
                  _gold.withValues(alpha: 0.45),
                ],
              ),
              border: Border.all(color: _yellow.withValues(alpha: 0.6)),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x33D9A441),
                  blurRadius: 10,
                  offset: Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: _deepBrown,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Icon(icon, color: _gold, size: 18),
                ),
                const Spacer(),
                Text(
                  label,
                  maxLines: 2,
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: _deepBrown,
                    height: 1.15,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Rotating fact with a big Baybayin sample; slides/fades between facts
  /// and shows which one you're on.
  Widget _buildFactCard() {
    final (sample, factEn, factFil) = _facts[_factIndex];
    final fact = context.tr(factEn, factFil);
    return GestureDetector(
      // Tap to skip to the next fact.
      onTap: () =>
          setState(() => _factIndex = (_factIndex + 1) % _facts.length),
      child: Container(
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            // Dark brown easing into a softer brown corner.
            colors: [_deepBrown, Color(0xFF6D4C41), Color(0xFF8A6A4A)],
            stops: [0, 0.6, 1],
          ),
          border: Border.all(color: _yellow.withValues(alpha: 0.7), width: 1.5),
          boxShadow: const [
            BoxShadow(
              color: Color(0x33D9A441),
              blurRadius: 22,
              offset: Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 450),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.08, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: Row(
                key: ValueKey(_factIndex),
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 84,
                    child: Text(
                      sample,
                      style: const TextStyle(
                        fontFamily: 'BaybayinCustom',
                        fontSize: 28,
                        color: _gold,
                        height: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      fact,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        height: 1.4,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                for (var i = 0; i < _facts.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 300),
                    margin: const EdgeInsets.only(right: 6),
                    width: i == _factIndex ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _factIndex
                          ? _gold
                          : Colors.white.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
                const Spacer(),
                Text(
                  context.tr('Tap for next', 'I-tap para sa susunod'),
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
