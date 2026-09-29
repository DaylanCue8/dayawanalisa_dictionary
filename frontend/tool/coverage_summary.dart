// Prints STATEMENT (line) COVERAGE per file from `flutter test --coverage`.
//
//   flutter test --coverage
//   dart run tool/coverage_summary.dart                  # logic files
//   dart run tool/coverage_summary.dart --all            # every file tested
//   dart run tool/coverage_summary.dart --out coverage/summary.md
//
// Reads coverage/lcov.info (LF = executable lines, LH = lines hit) - the
// same data genhtml uses - and needs no extra tools on Windows.
import 'dart:io';

/// The white-box targets: pure logic, no screen layout code.
const logicFiles = [
  'lib/services/tagalog_to_baybayin_local_translator.dart',
  'lib/services/recognition_outcome.dart',
  'lib/services/offline_recognizer.dart',
  'lib/services/app_settings.dart',
  'lib/services/app_language.dart',
  'lib/services/result_exporter.dart',
  'lib/screens/legal_screen.dart',
];

void main(List<String> args) {
  final lcov = File('coverage/lcov.info');
  if (!lcov.existsSync()) {
    stderr.writeln(
      'coverage/lcov.info not found - run `flutter test --coverage` first.',
    );
    exit(2);
  }
  final showAll = args.contains('--all');
  final outIndex = args.indexOf('--out');
  final outPath = outIndex >= 0 && outIndex + 1 < args.length
      ? args[outIndex + 1]
      : null;

  final files = <String, (int hit, int found, List<int> missed)>{};
  String? current;
  var missed = <int>[];
  var hit = 0, found = 0;
  for (final line in lcov.readAsLinesSync()) {
    if (line.startsWith('SF:')) {
      current = line.substring(3).replaceAll('\\', '/');
      final lib = current.indexOf('lib/');
      if (lib >= 0) current = current.substring(lib);
      missed = [];
      hit = found = 0;
    } else if (line.startsWith('DA:')) {
      final parts = line.substring(3).split(',');
      found++;
      if (int.parse(parts[1]) > 0) {
        hit++;
      } else {
        missed.add(int.parse(parts[0]));
      }
    } else if (line == 'end_of_record' && current != null) {
      files[current] = (hit, found, missed);
    }
  }

  final selected = showAll
      ? (files.keys.toList()..sort())
      : logicFiles.where(files.containsKey).toList();
  final notLoaded = showAll
      ? <String>[]
      : logicFiles.where((f) => !files.containsKey(f)).toList();

  final out = StringBuffer()
    ..writeln('| File | Lines hit | Coverage | Uncovered lines |')
    ..writeln('|---|---:|---:|---|');
  var totalHit = 0, totalFound = 0;
  for (final f in selected) {
    final (h, n, miss) = files[f]!;
    totalHit += h;
    totalFound += n;
    final pct = n == 0 ? 100.0 : 100 * h / n;
    out.writeln(
      '| $f | $h / $n | ${pct.toStringAsFixed(1)}% | ${_ranges(miss)} |',
    );
  }
  final totalPct = totalFound == 0 ? 0 : 100 * totalHit / totalFound;
  out..writeln(
    '| **Total** | **$totalHit / $totalFound** | **${totalPct.toStringAsFixed(1)}%** | |',
  );
  for (final f in notLoaded) {
    out.writeln('\n(no coverage data for $f - no test loads it)');
  }

  stdout.write(out);
  if (outPath != null) {
    File(outPath)
      ..createSync(recursive: true)
      ..writeAsStringSync('# Statement coverage\n\n$out');
    stdout.writeln('\nWritten to $outPath');
  }
}

/// [3, 4, 5, 9] -> "3-5, 9"
String _ranges(List<int> lines) {
  if (lines.isEmpty) return '-';
  final parts = <String>[];
  var start = lines.first, prev = lines.first;
  for (final n in lines.skip(1)) {
    if (n == prev + 1) {
      prev = n;
      continue;
    }
    parts.add(start == prev ? '$start' : '$start-$prev');
    start = prev = n;
  }
  parts.add(start == prev ? '$start' : '$start-$prev');
  return parts.join(', ');
}
