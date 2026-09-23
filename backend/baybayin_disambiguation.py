import itertools
import re
import unicodedata


def load_filipino_word_set(csv_path):
    """
    Loads the Tagalog word list CSV (one word per line, no header) into
    a lowercase set for O(1) dictionary-membership lookups.

    Uses utf-8-sig (not plain utf-8) so a leading byte-order-mark on
    the file's first line doesn't get glued onto its first word - that
    alone can silently make the very first entry in the file
    unmatchable forever, with nothing about it visible when the file
    is opened normally. Unicode-normalizing (NFC) each word similarly
    guards against a word that LOOKS identical on screen but is
    encoded as a different sequence of code points (e.g. a combining
    accent stored separately vs precomposed) than the word the OCR
    pipeline builds character-by-character.
    """
    word_set = set()
    with open(csv_path, encoding='utf-8-sig') as f:
        for line in f:
            word = unicodedata.normalize('NFC', line.strip()).lower()
            if word:
                word_set.add(word)
    return word_set


def generate_candidates(word_with_ambiguity):
    """
    Expands a word containing ambiguous {x/y} slots into every possible
    resolved spelling. E.g. 'l{e/i}pa' -> ['lepa', 'lipa']. This isn't
    limited to vowel slots - any single-letter-vs-single-letter
    ambiguity works the same way, e.g. Baybayin's shared D/R glyph
    ('{d/r}apa' -> ['dapa', 'rapa']), since the regex below matches any
    {x/y} pattern generically rather than hardcoding which letters can
    appear in a slot. Words with no ambiguous slot are returned
    unchanged as a single-item list.
    """
    slots = re.findall(r'\{[a-z]/[a-z]\}', word_with_ambiguity)
    if not slots:
        return [word_with_ambiguity]

    options_per_slot = [slot[1:-1].split('/') for slot in slots]
    template = re.sub(r'\{[a-z]/[a-z]\}', '{}', word_with_ambiguity)
    return [template.format(*combo) for combo in itertools.product(*options_per_slot)]


_SLOT_PATTERN = re.compile(r'\{[a-z]/[a-z]\}')
_FILIPINO_VOWELS = set('aeiou')


def _slot_positions_in_resolved(word_with_ambiguity):
    """
    Returns the character index each ambiguity slot will occupy in the
    fully-resolved (post-substitution) string, in the same left-to-right
    order generate_candidates iterates them in. Every slot always
    resolves to exactly one character (each option is a single
    letter), so this only needs to track how many literal characters
    and earlier one-character slots precede each slot.
    """
    positions = []
    resolved_index = 0
    cursor = 0
    for match in _SLOT_PATTERN.finditer(word_with_ambiguity):
        resolved_index += match.start() - cursor
        positions.append(resolved_index)
        resolved_index += 1
        cursor = match.end()
    return positions


def _dr_rule_score(candidate, slot_positions, slot_specs):
    """
    Scores a candidate by how well its resolved d/r letters follow the
    classic Filipino orthographic rule: D becomes R between two vowels
    (e.g. "dinig" -> "narinig"). +1 for each {d/r} slot where the
    resolved letter matches what the rule predicts from the
    candidate's OWN surrounding letters, -1 where it contradicts the
    rule. Non-d/r slots (e/i, o/u) don't affect the score, so this only
    ever influences ties that actually involve a d/r choice.
    """
    score = 0
    for pos, spec in zip(slot_positions, slot_specs):
        if spec != 'd/r':
            continue
        letter = candidate[pos]
        before = candidate[pos - 1] if pos > 0 else ''
        after = candidate[pos + 1] if pos + 1 < len(candidate) else ''
        intervocalic = before in _FILIPINO_VOWELS and after in _FILIPINO_VOWELS
        expected = 'r' if intervocalic else 'd'
        score += 1 if letter == expected else -1
    return score


def resolve_word(word_with_ambiguity, filipino_word_set):
    """
    Resolves one word's ambiguous slot(s) against the Filipino
    dictionary. Returns (resolved_word, status):
      'unambiguous' - no {e/i}/{o/u}/{d/r} slot existed at all
      'dictionary'  - exactly one candidate was a valid word
      'tie'         - multiple candidates were valid words. If any of
                      them differ by a {d/r} choice, the intervocalic
                      D/R rule (_dr_rule_score) picks the linguistically
                      correct one instead of just taking the first
                      candidate generated; ties with no d/r signal
                      still fall back to the first valid match, same as
                      before.
      'fallback'    - no candidate matched the dictionary; defaulted to
                      I over E, U over O (Filipino uses I/U far more
                      often than E/O), and D over R (a blind default
                      for when there's no dictionary OR intervocalic
                      evidence to go on at all)
    Tracking `status` lets the caller report how often each case
    occurs, which is useful evidence for evaluation write-ups.
    """
    word_lower = word_with_ambiguity.lower()
    candidates = generate_candidates(word_lower)

    if len(candidates) == 1:
        return candidates[0], 'unambiguous'

    valid = [c for c in candidates if c in filipino_word_set]

    if len(valid) == 1:
        return valid[0], 'dictionary'
    elif len(valid) > 1:
        slot_specs = [s[1:-1] for s in re.findall(r'\{[a-z]/[a-z]\}', word_lower)]
        slot_positions = _slot_positions_in_resolved(word_lower)
        best = max(valid, key=lambda c: _dr_rule_score(c, slot_positions, slot_specs))
        return best, 'tie'
    else:
        fallback = re.sub(r'\{e/i\}', 'i', word_lower)
        fallback = re.sub(r'\{o/u\}', 'u', fallback)
        fallback = re.sub(r'\{d/r\}', 'd', fallback)
        return fallback, 'fallback'


def resolve_output_parts(output_parts, filipino_word_set):
    """
    Applies resolve_word() to every word in every line of the OCR
    pipeline's output_parts (one string per detected line/row, words
    already space-joined within each line).

    Returns (resolved_lines, status_log):
      resolved_lines - same shape as output_parts, ambiguity resolved
      status_log     - list of {'word', 'resolved', 'status'} dicts,
                        one per word, useful for reporting how often
                        each resolution path fired
    """
    resolved_lines = []
    status_log = []

    for line in output_parts:
        resolved_words = []
        for word in line.split(' '):
            if word == '':
                resolved_words.append(word)
                continue
            resolved, status = resolve_word(word, filipino_word_set)
            resolved_words.append(resolved)
            status_log.append({'word': word, 'resolved': resolved, 'status': status})
        resolved_lines.append(' '.join(resolved_words))

    return resolved_lines, status_log