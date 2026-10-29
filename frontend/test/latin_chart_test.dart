import 'package:dayaw/services/app_language.dart';
import 'package:dayaw/services/tagalog_to_baybayin_local_translator.dart';
import 'package:dayaw/widgets/dayaw_style.dart';
import 'package:dayaw/widgets/latin_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('letters with no Baybayin equivalent are left out', () {
    final letters = [for (final (l, _) in latinChartLetters) l];
    for (final excluded in ['C', 'F', 'J', 'Q', 'V', 'X', 'Z']) {
      expect(letters, isNot(contains(excluded)));
    }
    expect(letters, contains('NG'));
  });

  test('every letter has a Baybayin character', () {
    final translator = TagalogToBaybayinLocalTranslator();
    for (final (letter, syllable) in latinChartLetters) {
      final glyph = translator.translate(syllable)['translated_text'];
      expect(glyph.toString(), isNotEmpty, reason: letter);
    }
  });

  testWidgets('the chart opens and shows the letters', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) =>
            ThemeScope(child: LanguageScope(child: child!)),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showLatinChart(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('NG'), findsOneWidget);
    expect(find.text('C'), findsNothing);
  });
}
