import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/app_language.dart';
import '../widgets/dayaw_style.dart';
import '../services/haptics.dart';
import 'baybayin_to_tagalog_view.dart';
import 'latin_to_baybayin_view.dart';

/// Both translators on one page: a shared header with a direction switch,
/// and the chosen mode below it. The two modes are different widget
/// types, so switching direction disposes one and starts the other fresh
/// (the same reset the separate tabs used to give).
class TranslateView extends StatefulWidget {
  const TranslateView({super.key});

  @override
  State<TranslateView> createState() => _TranslateViewState();
}

class _TranslateViewState extends State<TranslateView> {
  /// 0 = Baybayin to Latin (scan Baybayin), 1 = Latin to Baybayin.
  int _direction = 0;

  @override
  Widget build(BuildContext context) {
    DayawTheme.of(context);
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          child: _buildHeader(),
        ),
        Expanded(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: KeyedSubtree(
              key: ValueKey(_direction),
              // The views' own headers give way to the shared one above.
              child: _direction == 0
                  ? const BaybayinToTagalogView(header: SizedBox.shrink())
                  : const LatinToBaybayinView(header: SizedBox.shrink()),
            ),
          ),
        ),
      ],
    );
  }

  /// Half-turns made by the swap icon; each tap adds one.
  double _swapTurns = 0;

  void _swap() {
    Haptics.selection();
    setState(() {
      _direction = 1 - _direction;
      _swapTurns += 0.5;
    });
  }

  /// A raised box naming one side of the direction, with a small caption.
  Widget _languageBox(String language, String caption) {
    return Container(
      height: 58,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: neuRaised(borderRadius: BorderRadius.circular(18)),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        transitionBuilder: (child, animation) => FadeTransition(
          opacity: animation,
          child: ScaleTransition(
            scale: Tween(begin: 0.92, end: 1.0).animate(animation),
            child: child,
          ),
        ),
        child: Column(
          key: ValueKey(language),
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              caption,
              style: TextStyle(fontSize: 10.5, color: DayawColors.textMuted),
            ),
            const SizedBox(height: 2),
            Text(
              language,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: DayawColors.text,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The round swap key between the two boxes: a raised disc moulded
  /// from the page, its yellow arrows making a half turn on every tap.
  Widget _buildSwapButton() {
    return Tooltip(
      message: context.tr('Swap direction', 'Pagpalitin ang direksyon'),
      child: Container(
        width: 50,
        height: 50,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: DayawColors.bg,
          boxShadow: neuShadows(depth: 0.7),
        ),
        child: Material(
          color: Colors.transparent,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: _swap,
            child: AnimatedRotation(
              turns: _swapTurns,
              duration: const Duration(milliseconds: 320),
              curve: Curves.easeOutBack,
              child: Icon(
                Icons.swap_horiz_rounded,
                color: DayawColors.amber,
                size: 26,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final hint = _direction == 0
        ? context.tr(
            'Scan handwritten Baybayin and read it in Latin letters.',
            'I-scan ang sulat-kamay na Baybayin at basahin sa titik Latin.',
          )
        : context.tr(
            'Scan handwritten Latin letters and see them in Baybayin.',
            'I-scan ang sulat-kamay na titik Latin at makita sa Baybayin.',
          );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(
              context.tr('Recognize', 'Kilalanin'),
              // iOS large-title scale.
              style: TextStyle(
                fontSize: 32,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.8,
                color: DayawColors.text,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        // Source  [swap]  Target - like a translator's language bar.
        Row(
          children: [
            Expanded(
              child: _languageBox(
                _direction == 0 ? 'Baybayin' : 'Latin',
                context.tr('From', 'Mula sa'),
              ),
            ),
            const SizedBox(width: 12),
            _buildSwapButton(),
            const SizedBox(width: 12),
            Expanded(
              child: _languageBox(
                _direction == 0 ? 'Latin' : 'Baybayin',
                context.tr('To', 'Patungo sa'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 200),
          child: Text(
            hint,
            key: ValueKey(_direction),
            style: TextStyle(fontSize: 12.5, color: DayawColors.textMuted),
          ),
        ),
      ],
    );
  }
}
