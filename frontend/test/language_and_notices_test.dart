// White-box tests for the language switch and the legal notices.
//
// RULE-BASED CONSISTENCY: every notice section has the same number of
// English and Filipino paragraphs, none empty, so switching language
// never drops content.
// STATEMENT COVERAGE: tr() in both languages, LanguageScope rebuilds
// (including under a const parent), LegalScreen in both languages.
import 'package:dayaw/screens/legal_screen.dart';
import 'package:dayaw/services/app_language.dart';
import 'package:dayaw/services/app_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Greeting extends StatelessWidget {
  const _Greeting();
  @override
  Widget build(BuildContext context) =>
      Text(context.tr('Settings', 'Mga Setting'));
}

Widget app(Widget home) => MaterialApp(
  builder: (context, child) => LanguageScope(child: child!),
  home: home,
);

void main() {
  tearDown(() => AppSettings.instance.language = 'en');

  group('tr', () {
    test('picks the text for the current language', () {
      AppSettings.instance.language = 'en';
      expect(tr('Copy', 'Kopyahin'), 'Copy');
      AppSettings.instance.language = 'fil';
      expect(tr('Copy', 'Kopyahin'), 'Kopyahin');
    });

    test('an unsupported language code falls back to English', () {
      AppSettings.instance.language = 'jp';
      expect(AppSettings.instance.language, 'en');
      expect(tr('Copy', 'Kopyahin'), 'Copy');
    });

    test('exactly two languages are offered', () {
      expect(appLanguages.map((l) => l.$1), ['en', 'fil']);
    });
  });

  testWidgets('switching language rebuilds text, even under a const parent', (
    tester,
  ) async {
    await tester.pumpWidget(app(const Scaffold(body: _Greeting())));
    expect(find.text('Settings'), findsOneWidget);

    AppSettings.instance.language = 'fil';
    await tester.pump();
    expect(find.text('Mga Setting'), findsOneWidget);

    AppSettings.instance.language = 'en';
    await tester.pump();
    expect(find.text('Settings'), findsOneWidget);
  });

  group('legal notices', () {
    for (final document in LegalDocument.values) {
      test(
        '${document.name}: English and Filipino match section by section',
        () {
          expect(document.sections, isNotEmpty);
          for (final s in document.sections) {
            expect(s.titleEn.trim(), isNotEmpty);
            expect(s.titleFil.trim(), isNotEmpty);
            expect(s.bodyEn, isNotEmpty);
            expect(s.bodyFil.length, s.bodyEn.length, reason: s.titleEn);
            expect(s.bodyEn.every((p) => p.trim().isNotEmpty), isTrue);
            expect(s.bodyFil.every((p) => p.trim().isNotEmpty), isTrue);
          }
        },
      );
    }

    test('privacy notice covers data and compliance (RA 10173)', () {
      final text = LegalDocument.privacy.sections
          .expand((s) => s.bodyEn)
          .join(' ');
      expect(text, contains('10173'));
      expect(
        LegalDocument.privacy.sections.map((s) => s.titleEn),
        contains('Data and compliance'),
      );
    });

    test('each notice has its own icon', () {
      expect(
        LegalDocument.values.map((d) => d.icon).toSet(),
        hasLength(LegalDocument.values.length),
      );
    });

    testWidgets('LegalScreen.open navigates to the notice', (tester) async {
      await tester.pumpWidget(
        app(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => LegalScreen.open(context, LegalDocument.terms),
              child: const Text('open'),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.byType(LegalScreen), findsOneWidget);
      expect(find.text('Terms of Use'), findsOneWidget);
    });

    for (final lang in ['en', 'fil']) {
      testWidgets('LegalScreen renders every section ($lang)', (tester) async {
        AppSettings.instance.language = lang;
        for (final document in LegalDocument.values) {
          await tester.pumpWidget(app(LegalScreen(document: document)));
          await tester.pumpAndSettle();
          final first = document.sections.first;
          expect(
            find.text(lang == 'fil' ? first.titleFil : first.titleEn),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        }
      });
    }
  });
}
