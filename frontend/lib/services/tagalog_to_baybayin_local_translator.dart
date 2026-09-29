class TagalogToBaybayinLocalTranslator {
  // Defined once, then reused below, so 'da' and 'ra' are GUARANTEED to
  // be the exact same Unicode codepoint - Baybayin traditionally uses
  // one letter for both D and R sounds (they're allophones), so 'ra'
  // must never be typed as a separate literal glyph, which risks the
  // visually-similar-but-different RA codepoint (U+171D) being used by
  // mistake instead of DA (U+1707).
  static const String _daRaGlyph = 'ᜇ';
  final Map<String, String> baseMap = {
    'a': 'ᜀ',
    // Baybayin has only 3 independent vowel letters: A, I/E, and U/O.
    // 'e' and 'i' share the same letter; 'o' and 'u' share the same
    // letter. There is no separate glyph for a bare 'i' or 'u'.
    'e': 'ᜁ',
    'i': 'ᜁ',
    'o': 'ᜂ',
    'u': 'ᜂ',
    'ba': 'ᜊ',
    'ka': 'ᜃ',
    'da': _daRaGlyph,
    'ra': _daRaGlyph,
    'ga': 'ᜄ',
    'ha': 'ᜑ',
    'la': 'ᜎ',
    'ma': 'ᜋ',
    'na': 'ᜈ',
    'nga': 'ᜅ',
    'pa': 'ᜉ',
    'sa': 'ᜐ',
    'ta': 'ᜆ',
    'wa': 'ᜏ',
    'ya': 'ᜌ',
  };

  // Unicode Baybayin only defines two vowel-sign kudlits: VOWEL SIGN I
  // (U+1712, used for both I and E readings) and VOWEL SIGN U (U+1713,
  // used for both U and O readings). There is no distinct E or U sign,
  // so kudlitE/kudlitU reuse the same marks as kudlitI/kudlitO.
  final String kudlitI = '\u1712';
  final String kudlitE = '\u1712';
  final String kudlitU = '\u1713';
  final String kudlitO = '\u1713';
  final String virama = '\u1714';
  final String danda = '᜵';
  final String doubleDanda = '᜶';

  Map<String, dynamic> translate(String text) {
    if (text.trim().isEmpty) {
      return {'translated_text': '', 'confidence': 0.0};
    }

    final originalText = text.toLowerCase().trim();
    double confidence = 100.0;

    final nonNativeMatches = RegExp(r'[cfjqzvx]').allMatches(originalText);
    if (nonNativeMatches.isNotEmpty) {
      confidence -= nonNativeMatches.length * 15;
    }

    return {
      'translated_text': breakdown(originalText).map((t) => t.baybayin).join(),
      'confidence': confidence < 0 ? 0.0 : confidence,
    };
  }

  /// The translation split into its pieces: one entry per syllable (or
  /// lone consonant / vowel / space / punctuation), each with the Latin
  /// text it came from and the Baybayin written for it. Joining every
  /// `baybayin` gives exactly what [translate] returns.
  List<({String latin, String baybayin})> breakdown(String text) {
    final originalText = text.toLowerCase().trim();
    final pieces = <({String latin, String baybayin})>[];
    var workingText = originalText.replaceAll('ng', 'NG');

    for (final match in _tokenPattern.allMatches(workingText)) {
      pieces.add((
        latin: match.group(0)!.replaceAll('NG', 'ng'),
        baybayin: _pieceFor(match),
      ));
    }

    return pieces;
  }

  /// Tokenizer for the NG-marked, lower-cased input. One group per rule,
  /// tried left to right:
  ///   1. the word 'mga' - pronounced "ma-nga" (ma + nga), NOT "ma-ga";
  ///      matched with word boundaries so it works anywhere in the text
  ///   2. consonant + vowel syllable (CV), 'NG' counting as one consonant
  ///   3. lone consonant (no vowel after it)
  ///   4. lone vowel
  ///   5. whitespace
  ///   6. '.' or ','
  /// Anything else (digits, c/f/j/q/v/x/z, other punctuation) matches no
  /// group and is simply left out of the output.
  ///
  /// Every group is reachable - group 2 REQUIRES a consonant, so a lone
  /// vowel always falls to group 4 - which keeps every line of
  /// [_pieceFor] coverable by tests.
  static final RegExp _tokenPattern = RegExp(
    r'(\bmga\b)|(NG[aeiou]|[bkdrghlmnpstwry][aeiou])|(NG|[bkdrghlmnpstwry])|([aeiou])|(\s+)|([.,])',
  );

  /// The Baybayin for one matched piece of the (NG-marked) input.
  String _pieceFor(RegExpMatch match) {
    final mgaWord = match.group(1);
    final cv = match.group(2);
    final v = match.group(4);
    final space = match.group(5);
    final punct = match.group(6);

    if (mgaWord != null) return '${baseMap['ma']}${baseMap['nga']}';
    if (space != null) return space;
    if (punct != null) return punct == '.' ? doubleDanda : danda;
    if (v != null) return baseMap[v]!;
    if (cv != null) {
      final consonant = cv.substring(0, cv.length - 1);
      final vowel = cv.substring(cv.length - 1);
      return baseMap[_syllableKey(consonant)]! + _kudlitFor(vowel);
    }
    // Only group 3 is left: a consonant with no vowel, written with the
    // virama (vowel-killer) mark.
    return baseMap[_syllableKey(match.group(3)!)]! + virama;
  }

  /// baseMap key of a consonant's "+a" syllable: 'b' -> 'ba', 'r' -> 'ra'
  /// (same glyph as 'da'), 'NG' -> 'nga'.
  String _syllableKey(String consonant) =>
      consonant == 'NG' ? 'nga' : '${consonant}a';

  /// Vowel mark after a consonant: kudlit above for e/i, below for o/u,
  /// none for a (the consonant already carries "a").
  String _kudlitFor(String vowel) => switch (vowel) {
    'e' => kudlitE,
    'i' => kudlitI,
    'o' => kudlitO,
    'u' => kudlitU,
    _ => '',
  };
}
