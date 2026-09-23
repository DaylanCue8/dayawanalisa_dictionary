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

    var workingText = originalText.replaceAll('ng', 'NG');

    // 'mga' is pronounced "ma-nga" (ma + nga), NOT "ma-ga". Handled as
    // its own token, with a word boundary, so it works anywhere in the
    // text - not just when it's the entire input.
    final pattern = RegExp(
      r'(\bmga\b)|(NG[aeiou]|(?:[bkdrghlmnpstwry])?[aeiou])|(NG|[bkdrghlmnpstwry])|([aeiou])|(\s+)|(\.|\,)',
    );

    final buffer = StringBuffer();
    final matches = pattern.allMatches(workingText);

    for (final match in matches) {
      final mgaWord = match.group(1);
      final cv = match.group(2);
      final c = match.group(3);
      final v = match.group(4);
      final space = match.group(5);
      final punct = match.group(6);

      if (mgaWord != null) {
        buffer.write('${baseMap['ma']}${baseMap['nga']}');
        continue;
      }

      if (space != null) {
        buffer.write(space);
        continue;
      }

      if (punct != null) {
        if (punct == '.') {
          buffer.write(doubleDanda);
        } else if (punct == ',') {
          buffer.write(danda);
        }
        continue;
      }

      final vowelToken = v ??
          (cv != null && cv.length == 1 && RegExp(r'^[aeiou]$').hasMatch(cv) ? cv : null);
      if (vowelToken != null) {
        buffer.write(baseMap[vowelToken] ?? '');
        continue;
      }

      if (cv != null) {
        final vowelPart = cv.substring(cv.length - 1);
        final consPart = cv.substring(0, cv.length - 1);

        String key;
        if (consPart == 'r') {
          key = 'ra';
        } else if (consPart == 'NG') {
          key = 'nga';
        } else {
          key = '${consPart}a';
        }

        final base = baseMap[key] ?? '';

        if (vowelPart == 'e') {
          buffer.write(base + kudlitE);
        } else if (vowelPart == 'i') {
          buffer.write(base + kudlitI);
        } else if (vowelPart == 'o') {
          buffer.write(base + kudlitO);
        } else if (vowelPart == 'u') {
          buffer.write(base + kudlitU);
        } else {
          buffer.write(base);
        }
      } else if (c != null) {
        String key;
        if (c == 'r') {
          key = 'ra';
        } else if (c == 'NG') {
          key = 'nga';
        } else {
          key = '${c}a';
        }

        final base = baseMap[key] ?? '';
        if (base.isNotEmpty) {
          buffer.write(base + virama);
        }
      }
    }

    return {
      'translated_text': buffer.toString(),
      'confidence': confidence < 0 ? 0.0 : confidence,
    };
  }
}