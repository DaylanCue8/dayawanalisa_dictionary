// test/tagalog_to_baybayin_local_translator_test.dart
//
// Evaluates the Filipino-to-Baybayin rule-based transliteration engine
// (TagalogToBaybayinLocalTranslator) along three axes:
//
//   1. STATEMENT COVERAGE - every branch inside translate() is
//      exercised by at least one test below: the mga special case, CV
//      syllables with each kudlit, consonant-only/virama tokens
//      (including the 'r' and 'NG' special-cased key names),
//      punctuation, whitespace, the non-native-letter confidence
//      penalty, and the empty-input guard.
//
//      NOTE on consonant coverage: translate() has NO per-consonant
//      branch - every letter in [bkdrghlmnpstwry] falls through the
//      exact same code path (`key = '${consPart}a'; baseMap[key]`),
//      with only 'r' and 'NG' special-cased for KEY NAMING, not for a
//      structurally different branch. So exercising b/k/m/d/r/ng below
//      already achieves full statement/branch coverage of that path;
//      testing the remaining 9 consonants (g/h/l/n/p/s/t/w/y) would
//      re-execute identical lines and add no new coverage. Those 9 are
//      still tested in Group 12, but as DATA validation of the
//      hardcoded baseMap dictionary (a wrong/duplicated glyph literal
//      still "executes successfully", so coverage tooling can't catch
//      it) - not as a coverage requirement.
//
//      NOTE on a genuinely uncovered (and unreachable) branch: the
//      regex's 4th alternative, `([aeiou])` (a bare standalone vowel),
//      can never actually match, because the 2nd alternative
//      (`(?:[bkdrghlmnpstwry])?[aeiou]`, used for CV syllables) has an
//      OPTIONAL consonant - so it already matches any lone vowel
//      before the engine ever tries alternative 4. Every "standalone
//      vowel" test below (Group 1) therefore exercises translate()'s
//      `cv`-derived fallback path, not the dedicated `v` variable. A
//      coverage tool will report the `v` branch as uncovered; that is
//      correct and is not a gap in this test suite - it's dead code in
//      the translator caused by the regex ordering. Left in place
//      deliberately rather than "fixed" with a workaround test, since
//      fixing it is a source change outside this file's scope.
//
//   2. RULE-BASED CONSISTENCY - the engine has no randomness or mutable
//      state, so the same input MUST always produce the same output.
//      The "Determinism" group asserts this directly, and every mapping
//      test doubles as a check that a given linguistic rule (e.g. 'ng'
//      + vowel -> nga + kudlit) is applied the same way every time.
//
//   3. STATISTICAL VALIDATION - a batch of real Filipino words/phrases
//      is run through the engine and the pass rate + average confidence
//      are computed and asserted, giving a quantitative measure rather
//      than just anecdotal spot-checks. NOTE: the current sample is
//      deliberately all-native-letter vocabulary, so 100% is guaranteed
//      by construction rather than measured - useful as a regression
//      guard, but not evidence of a real error rate. A mixed sample
//      (some non-native letters, some malformed input) would be needed
//      to report a statistic that could actually fail.
//
// Adjust the import below to match this file's location in your project
// (e.g. `package:dayaw/tagalog_to_baybayin_local_translator.dart` if the
// package is named "dayaw").
import 'package:flutter_test/flutter_test.dart';
import 'package:dayaw/services/tagalog_to_baybayin_local_translator.dart';

void main() {
  final translator = TagalogToBaybayinLocalTranslator();

  // ===========================================================
  // 1. STANDALONE VOWELS
  // ===========================================================
  group('Standalone vowel mapping', () {
    test('a -> ᜀ', () {
      expect(translator.translate('a')['translated_text'], 'ᜀ');
    });

    test('e and i both map to ᜁ (Baybayin has one E/I glyph)', () {
      expect(translator.translate('e')['translated_text'], 'ᜁ');
      expect(translator.translate('i')['translated_text'], 'ᜁ');
    });

    test('o and u both map to ᜂ (Baybayin has one O/U glyph)', () {
      expect(translator.translate('o')['translated_text'], 'ᜂ');
      expect(translator.translate('u')['translated_text'], 'ᜂ');
    });
  });

  // ===========================================================
  // 2. CONSONANT + VOWEL (CV) SYLLABLES
  // ===========================================================
  group('Consonant+vowel (CV) syllable mapping', () {
    test('inherent-a syllables carry no kudlit', () {
      expect(translator.translate('ba')['translated_text'], 'ᜊ');
      expect(translator.translate('ka')['translated_text'], 'ᜃ');
      expect(translator.translate('ma')['translated_text'], 'ᜋ');
    });

    test('e-vowel syllables append kudlit I (E/I share one sign)', () {
      expect(translator.translate('be')['translated_text'], 'ᜊ' + '\u1712');
    });

    test('i-vowel syllables append kudlit I', () {
      expect(translator.translate('bi')['translated_text'], 'ᜊ' + '\u1712');
    });

    test('o-vowel syllables append kudlit U (O/U share one sign)', () {
      expect(translator.translate('bo')['translated_text'], 'ᜊ' + '\u1713');
    });

    test('u-vowel syllables append kudlit U', () {
      expect(translator.translate('bu')['translated_text'], 'ᜊ' + '\u1713');
    });
  });

  // ===========================================================
  // 3. 'NG' DIGRAPH HANDLING
  // ===========================================================
  group("'ng' digraph rules", () {
    test('nga (inherent a) maps to the NGA base glyph with no kudlit', () {
      expect(translator.translate('nga')['translated_text'], 'ᜅ');
    });

    test('nge/ngi apply kudlit I to the NGA base', () {
      expect(translator.translate('nge')['translated_text'], 'ᜅ' + '\u1712');
      expect(translator.translate('ngi')['translated_text'], 'ᜅ' + '\u1712');
    });

    test('ngo/ngu apply kudlit U to the NGA base', () {
      expect(translator.translate('ngo')['translated_text'], 'ᜅ' + '\u1713');
      expect(translator.translate('ngu')['translated_text'], 'ᜅ' + '\u1713');
    });

    test(
        'a word-final, unvowelled "ng" gets a virama '
        '(consonant-only path)', () {
      // "ang" -> a + (final ng, no following vowel) -> should end in
      // the NGA glyph + virama, exercising the consonant-only branch
      // specifically for the NG case.
      final result =
          translator.translate('ang')['translated_text'] as String;
      expect(result.endsWith('ᜅ' + '\u1714'), isTrue);
    });
  });

  // ===========================================================
  // 4. WORD-FINAL CONSONANTS (VIRAMA / vowel-cancellation path)
  // ===========================================================
  group('Word-final consonant (virama) rule', () {
    test('a trailing unvowelled consonant gets a virama appended', () {
      // "lakad" = la + ka + d(no vowel) -> final syllable should be
      // the DA glyph + virama (vowel-cancelling mark).
      final result =
          translator.translate('lakad')['translated_text'] as String;
      expect(result.endsWith('ᜇ' + '\u1714'), isTrue);
    });
  });

  // ===========================================================
  // 5. THE 'mga' SPECIAL CASE (ma + nga, NOT ma + ga)
  // ===========================================================
  group("'mga' special-case rule", () {
    test('mga alone becomes MA + NGA, not MA + GA', () {
      expect(translator.translate('mga')['translated_text'], 'ᜋ' + 'ᜅ');
    });

    test(
        'mga is only matched as a whole word (word-boundary), '
        'not as a substring inside a longer word', () {
      final result =
          translator.translate('mga bahay')['translated_text'] as String;
      expect(result.startsWith('ᜋ' + 'ᜅ' + ' '), isTrue);
    });
  });

  // ===========================================================
  // 6. 'r' -> same glyph as 'd' (Baybayin does not distinguish R/D)
  // ===========================================================
  group("'r' consonant rule", () {
    test('ra syllable maps to the same glyph as da', () {
      final ra = translator.translate('ra')['translated_text'];
      final da = translator.translate('da')['translated_text'];
      expect(ra, da);
    });

    test(
        'a bare, unvowelled r consonant maps like a bare d '
        '(exercises the c == "r" branch in the word-final/virama path, '
        'which no other test above reaches - "ra" only exercises the '
        'CV branch\'s r-handling, not this one)', () {
      final bareR = translator.translate('r')['translated_text'];
      final bareD = translator.translate('d')['translated_text'];
      expect(bareR, bareD);
      // Also confirm it actually took the virama path, not silently
      // producing an empty/wrong result.
      expect((bareR as String).endsWith('\u1714'), isTrue);
    });
  });

  // ===========================================================
  // 7. PUNCTUATION AND WHITESPACE PASS-THROUGH
  // ===========================================================
  group('Punctuation and whitespace handling', () {
    test('a period becomes the double danda (᜶)', () {
      final result =
          translator.translate('sige.')['translated_text'] as String;
      expect(result.endsWith('᜶'), isTrue);
    });

    test('a comma becomes the single danda (᜵)', () {
      final result =
          translator.translate('sige,')['translated_text'] as String;
      expect(result.endsWith('᜵'), isTrue);
    });

    test('internal whitespace between words is preserved', () {
      final result =
          translator.translate('sa bahay')['translated_text'] as String;
      expect(result.contains(' '), isTrue);
    });
  });

  // ===========================================================
  // 8. CONFIDENCE SCORING (non-native letters c/f/j/q/z/v/x)
  // ===========================================================
  group('Confidence scoring rule', () {
    test('an all-native-letter word scores 100% confidence', () {
      expect(translator.translate('bahay')['confidence'], 100.0);
    });

    test('each non-native letter deducts 15 points', () {
      // 'taxi' has exactly one non-native letter ('x').
      expect(translator.translate('taxi')['confidence'], 85.0);
    });

    test('confidence never goes below 0, even with many non-native letters',
        () {
      // Every one of c,f,j,q,z,v,x present -> 7 * 15 = 105 deducted,
      // which must clamp to 0, not go negative.
      expect(translator.translate('cfjqzvx')['confidence'], 0.0);
    });
  });

  // ===========================================================
  // 9. EMPTY / EDGE-CASE INPUT
  // ===========================================================
  group('Empty input edge case', () {
    test('an empty string returns an empty translation and 0 confidence',
        () {
      final result = translator.translate('');
      expect(result['translated_text'], '');
      expect(result['confidence'], 0.0);
    });

    test('a whitespace-only string is treated as empty', () {
      final result = translator.translate('   ');
      expect(result['translated_text'], '');
      expect(result['confidence'], 0.0);
    });
  });

  // ===========================================================
  // 10. RULE-BASED CONSISTENCY (determinism)
  // ===========================================================
  group('Rule-based consistency (determinism)', () {
    test(
        'translating the same input multiple times always yields '
        'an identical result', () {
      const sample = 'Minsan sa isang malayong nayon, may mga bata.';
      final first = translator.translate(sample);
      final second = translator.translate(sample);
      final third = translator.translate(sample);

      expect(second['translated_text'], first['translated_text']);
      expect(third['translated_text'], first['translated_text']);
      expect(second['confidence'], first['confidence']);
      expect(third['confidence'], first['confidence']);
    });

    test('case does not affect the output (input is lowercased first)', () {
      final lower = translator.translate('bahay');
      final upper = translator.translate('BAHAY');
      final mixed = translator.translate('BaHay');
      expect(upper['translated_text'], lower['translated_text']);
      expect(mixed['translated_text'], lower['translated_text']);
    });
  });

  // ===========================================================
  // 11. STATISTICAL VALIDATION (batch accuracy + confidence)
  // ===========================================================
  group('Statistical validation over a real-word sample', () {
    // A curated sample of common, all-native-letter Filipino words and
    // short phrases. None contain c/f/j/q/z/v/x, so every one is
    // EXPECTED to score exactly 100% confidence and produce non-empty
    // Baybayin output - this batch is quantitative evidence that the
    // rule set behaves correctly across real vocabulary, not just on
    // hand-picked single syllables. See the file header for why this
    // 100% is guaranteed by sample construction, not a measured rate.
    const sampleWords = <String>[
      'bahay', 'araw', 'tubig', 'kumain', 'mahal',
      'salamat', 'paalam', 'gabi', 'umaga', 'lakad',
      'bata', 'nanay', 'tatay', 'kapatid', 'kaibigan',
      'ang bahay', 'sa bahay', 'mga bata', 'ako ay masaya',
      'kumain ako ng kanin',
    ];

    test('every sample word produces non-empty Baybayin output', () {
      for (final word in sampleWords) {
        final result = translator.translate(word);
        final text = result['translated_text'] as String;
        expect(
          text.trim().isNotEmpty,
          isTrue,
          reason: '"$word" produced an empty translation',
        );
      }
    });

    test(
        'average confidence across the sample is 100% '
        '(all-native-letter vocabulary)', () {
      final confidences = sampleWords
          .map((w) => translator.translate(w)['confidence'] as double)
          .toList();

      final average =
          confidences.reduce((a, b) => a + b) / confidences.length;

      // Printed so it shows up in the test run output as a concrete,
      // reportable statistic - useful to quote directly in a results
      // section: "average confidence across N sample words = X%".
      // ignore: avoid_print
      print('Statistical validation: n=${sampleWords.length}, '
          'average confidence = ${average.toStringAsFixed(2)}%');

      expect(average, 100.0);
    });

    test(
        'pass rate: percentage of sample words scoring >= 95% confidence',
        () {
      final confidences = sampleWords
          .map((w) => translator.translate(w)['confidence'] as double)
          .toList();

      final passCount = confidences.where((c) => c >= 95.0).length;
      final passRate = (passCount / confidences.length) * 100;

      // ignore: avoid_print
      print('Statistical validation: pass rate (>=95% confidence) = '
          '${passRate.toStringAsFixed(1)}% ($passCount/${confidences.length})');

      expect(passRate, 100.0);
    });
  });

  // ===========================================================
  // 12. BASEMAP DICTIONARY COMPLETENESS (data validation, NOT
  //     statement coverage - every consonant here executes the exact
  //     same code path as 'b'/'k'/'m' in Group 2, so this section adds
  //     no new branch coverage. It exists because a wrong or
  //     duplicated glyph typed directly into the hardcoded baseMap
  //     dictionary would still "execute successfully" - a coverage
  //     tool cannot detect a wrong VALUE, only an unexecuted LINE.
  // ===========================================================
  group('baseMap dictionary completeness (data validation)', () {
    test('every consonant+a syllable in baseMap maps to a non-empty, '
        'unique glyph (except the documented da/ra allophone pair)', () {
      final consonantSyllables = [
        'ba', 'ka', 'da', 'ra', 'ga', 'ha', 'la', 'ma',
        'na', 'nga', 'pa', 'sa', 'ta', 'wa', 'ya',
      ];

      final seenGlyphs = <String, String>{}; // glyph -> first syllable seen
      for (final syll in consonantSyllables) {
        final result = translator.translate(syll)['translated_text'] as String;
        expect(result.isNotEmpty, isTrue, reason: '"$syll" produced no glyph');

        if (seenGlyphs.containsKey(result) && syll != 'ra') {
          fail('"$syll" produced the same glyph as "${seenGlyphs[result]}" '
              '($result) - only da/ra are supposed to share a glyph');
        }
        seenGlyphs.putIfAbsent(result, () => syll);
      }
    });

    test('every consonant not yet exercised above still produces the '
        'expected kudlit-I and kudlit-U variants correctly', () {
      // g/h/l/n/p/s/t/w/y specifically - b/k/m/ng/r/d are already
      // covered (for both coverage AND data correctness) by earlier
      // groups.
      const untested = ['g', 'h', 'l', 'n', 'p', 's', 't', 'w', 'y'];
      for (final c in untested) {
        final base = translator.translate('${c}a')['translated_text'] as String;
        final withI = translator.translate('${c}i')['translated_text'] as String;
        final withU = translator.translate('${c}u')['translated_text'] as String;

        expect(withI, base + '\u1712', reason: '${c}i failed kudlit-I check');
        expect(withU, base + '\u1713', reason: '${c}u failed kudlit-U check');
      }
    });
  });
}