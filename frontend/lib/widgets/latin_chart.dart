import 'package:flutter/material.dart';

import '../services/app_language.dart';
import '../services/tagalog_to_baybayin_local_translator.dart';
import 'dayaw_style.dart';

/// Latin letters that have a Baybayin form, each with the syllable it
/// stands for. C, F, J, Q, V, X and Z have no Baybayin equivalent, so
/// they are left out. NG is one letter in Baybayin.
const latinChartLetters = [
  ('A', 'a'), ('B', 'ba'), ('D', 'da'), ('E', 'e'), ('G', 'ga'),
  ('H', 'ha'), ('I', 'i'), ('K', 'ka'), ('L', 'la'), ('M', 'ma'),
  ('N', 'na'), ('NG', 'nga'), ('O', 'o'), ('P', 'pa'), ('R', 'ra'),
  ('S', 'sa'), ('T', 'ta'), ('U', 'u'), ('W', 'wa'), ('Y', 'ya'),
];

/// Opens the chart guide: every supported Latin letter beside its
/// Baybayin character, worked out by the app's own translator so the
/// chart always matches what the app writes.
void showLatinChart(BuildContext context) {
  showDialog<void>(
    context: context,
    builder: (context) => const _LatinChartDialog(),
  );
}

class _LatinChartDialog extends StatelessWidget {
  const _LatinChartDialog();

  @override
  Widget build(BuildContext context) {
    final translator = TagalogToBaybayinLocalTranslator();
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: DayawColors.bg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 460,
          maxHeight: MediaQuery.sizeOf(context).height * 0.85,
        ),
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(18, 20, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                context.tr('Chart Guide', 'Gabay sa Tsart'),
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                  color: DayawColors.text,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                context.tr(
                  'Each Latin letter and its Baybayin character.',
                  'Bawat titik Latin at ang katumbas nitong Baybayin.',
                ),
                style: TextStyle(fontSize: 13, color: DayawColors.textMuted),
              ),
              const SizedBox(height: 18),
              GridView.count(
                crossAxisCount: 4,
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                mainAxisSpacing: 14,
                crossAxisSpacing: 14,
                childAspectRatio: 0.82,
                children: [
                  for (final (letter, syllable) in latinChartLetters)
                    _LetterTile(
                      letter: letter,
                      syllable: syllable,
                      baybayin:
                          translator
                              .translate(syllable)['translated_text']
                              ?.toString() ??
                          '',
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Text(
                context.tr(
                  'C, F, J, Q, V, X and Z have no Baybayin equivalent, so '
                      'they are not shown. D and R share one character, as '
                      'do E and I, and O and U.',
                  'Walang katumbas sa Baybayin ang C, F, J, Q, V, X at Z, '
                      'kaya hindi ito ipinapakita. Iisang karakter ang D at '
                      'R, gayundin ang E at I, at ang O at U.',
                ),
                style: TextStyle(
                  fontSize: 12,
                  height: 1.4,
                  color: DayawColors.textMuted,
                ),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  style: TextButton.styleFrom(
                    foregroundColor: DayawColors.text,
                  ),
                  child: Text(context.tr('Close', 'Isara')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One raised tile: Latin letter, its Baybayin character, the syllable.
class _LetterTile extends StatelessWidget {
  final String letter;
  final String syllable;
  final String baybayin;

  const _LetterTile({
    required this.letter,
    required this.syllable,
    required this.baybayin,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: neuRaised(
        borderRadius: BorderRadius.circular(16),
        depth: 0.45,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            letter,
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: DayawColors.text,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            baybayin,
            style: TextStyle(
              fontFamily: 'BaybayinCustom',
              fontSize: 24,
              height: 1.2,
              color: DayawColors.amber,
            ),
          ),
          Text(
            syllable,
            style: TextStyle(fontSize: 11, color: DayawColors.textMuted),
          ),
        ],
      ),
    );
  }
}
