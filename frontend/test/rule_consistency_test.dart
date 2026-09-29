// RULE-BASED CONSISTENCY of the Filipino -> Baybayin engine, checked on
// EVERY word of the app's Tagalog word list (android/app/src/main/python/
// Tagalog_words_74419+.csv), not just hand-picked examples.
//
// For each input the engine must obey these rules:
//   R1  determinism - the same input always gives the same output
//   R2  translate() == the breakdown pieces joined (one source of truth)
//   R3  the output uses only Baybayin letters/marks, dandas and spaces
//   R4  confidence = 100 - 15 x (number of c/f/j/q/v/x/z), never below 0
//   R5  consonant + e/i ends in kudlit-I, + o/u in kudlit-U, + a has none
//   R6  a consonant with no vowel ends in the virama
//   R7  lone vowels: a -> A, e/i -> I, o/u -> U
//   R8  d and r are written with the same letter (allophones)
//   R9  'ng' is one letter (NGA), never n + g
// The test prints how many words / pieces each rule was checked on.
import 'dart:io';

import 'package:dayaw/services/tagalog_to_baybayin_local_translator.dart';
import 'package:flutter_test/flutter_test.dart';

const kudlitI = 'ᜒ', kudlitU = 'ᜓ', virama = '᜔';
final baybayinOnly = RegExp(r'^[ᜀ-᜔᜵᜶\s]*$');
final consonantVowel = RegExp(r'^(ng|[bkdrghlmnpstwry])([aeiou])$');
final loneConsonant = RegExp(r'^(ng|[bkdrghlmnpstwry])$');

List<String> wordList() {
  final file = File('android/app/src/main/python/Tagalog_words_74419+.csv');
  return file
      .readAsLinesSync()
      .map((l) => l.split(',').first.trim())
      .where((w) => w.isNotEmpty)
      .toSet()
      .toList();
}

void main() {
  final translator = TagalogToBaybayinLocalTranslator();
  final words = wordList();

  // 74,419 lines in the file; about 43,000 once duplicates are removed.
  test(
    'word list is available',
    () => expect(words.length, greaterThan(40000)),
  );

  test('rules R1-R9 hold for every word in the word list', () {
    final failures = <String>[];
    var pieces = 0;
    void check(bool ok, String rule, String word, [String detail = '']) {
      if (!ok && failures.length < 20) failures.add('$rule "$word" $detail');
    }

    for (final word in words) {
      final first = translator.translate(word);
      final second = translator.translate(word);
      final text = first['translated_text'] as String;

      check(text == second['translated_text'], 'R1', word);
      check(first['confidence'] == second['confidence'], 'R1', word);

      final breakdown = translator.breakdown(word);
      check(breakdown.map((p) => p.baybayin).join() == text, 'R2', word);
      check(baybayinOnly.hasMatch(text), 'R3', word, text);

      final foreign = RegExp('[cfjqzvx]').allMatches(word.toLowerCase()).length;
      final expected = (100.0 - 15 * foreign).clamp(0.0, 100.0);
      check(
        first['confidence'] == expected,
        'R4',
        word,
        '${first['confidence']}',
      );

      for (final piece in breakdown) {
        pieces++;
        final cv = consonantVowel.firstMatch(piece.latin);
        if (cv != null) {
          final vowel = cv.group(2)!;
          // Baybayin letters and marks are single UTF-16 code units.
          final mark = piece.baybayin[piece.baybayin.length - 1];
          if ('ei'.contains(vowel))
            check(mark == kudlitI, 'R5', word, piece.latin);
          if ('ou'.contains(vowel))
            check(mark == kudlitU, 'R5', word, piece.latin);
          if (vowel == 'a')
            check(piece.baybayin.length == 1, 'R5', word, piece.latin);
          if (cv.group(1) == 'ng') {
            check(piece.baybayin.startsWith('ᜅ'), 'R9', word, piece.latin);
          }
        }
        if (loneConsonant.hasMatch(piece.latin)) {
          check(piece.baybayin.endsWith(virama), 'R6', word, piece.latin);
        }
      }
    }
    // ignore: avoid_print
    print(
      'Rule consistency: ${words.length} words, $pieces pieces checked, '
      '${failures.length} violations',
    );
    expect(failures, isEmpty, reason: failures.join('\n'));
  });

  test('R7 lone vowels map to the three vowel letters', () {
    expect(translator.translate('a')['translated_text'], 'ᜀ');
    for (final v in ['e', 'i']) {
      expect(translator.translate(v)['translated_text'], 'ᜁ');
    }
    for (final v in ['o', 'u']) {
      expect(translator.translate(v)['translated_text'], 'ᜂ');
    }
  });

  test('R8 d and r always give the same letter', () {
    for (final v in ['a', 'e', 'i', 'o', 'u', '']) {
      expect(
        translator.translate('d$v')['translated_text'],
        translator.translate('r$v')['translated_text'],
      );
    }
  });

  test('R9 ng is one letter, not n + g', () {
    final pieces = translator.breakdown('ngayon');
    expect(pieces.first.latin, 'nga');
    expect(pieces.first.baybayin, 'ᜅ');
  });

  test('unsupported characters are dropped, not crashing', () {
    for (final input in ['123', '!!!', 'ñ', 'x', '😀', '\t\n']) {
      expect(() => translator.translate(input), returnsNormally);
      expect(
        baybayinOnly.hasMatch(translator.translate(input)['translated_text']),
        isTrue,
      );
    }
  });
}
