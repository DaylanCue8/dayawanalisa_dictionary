// Every theme (Light, Dark, System) must render the shared pieces without
// errors, and switching theme must repaint them live.
import 'package:dayaw/main.dart';
import 'package:dayaw/screens/legal_screen.dart';
import 'package:dayaw/services/app_language.dart';
import 'package:dayaw/services/app_settings.dart';
import 'package:dayaw/widgets/dayaw_style.dart';
import 'package:dayaw/widgets/glass.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget app(Widget home) => MaterialApp(
  builder: (context, child) => ThemeScope(child: LanguageScope(child: child!)),
  home: home,
);

final sample = Scaffold(
  body: GlassBackground(
    child: ListView(
      children: const [
        DayawHeroHeader(title: 'Title', subtitle: 'Sub', baybayin: 'ᜊᜌ'),
        DayawSectionTitle('Section', Icons.star),
        GlassContainer(padding: EdgeInsets.all(18), child: Text('card')),
        GlassContainer(
          tint: Color(0xA6FFF4B8),
          padding: EdgeInsets.all(18),
          child: Text('accent'),
        ),
        GlassContainer(
          tint: Color(0x8C000000),
          padding: EdgeInsets.all(3),
          child: Text('overlay'),
        ),
        SizedBox(height: 56, child: GlassBar(child: SizedBox.expand())),
      ],
    ),
  ),
);

void main() {
  tearDown(() {
    AppSettings.instance.theme = 'system';
    DayawColors.dark = false;
  });

  for (final dark in [false, true]) {
    final name = dark ? 'dark' : 'light';
    testWidgets('$name palette renders the shared widgets', (tester) async {
      DayawColors.dark = dark;
      await tester.pumpWidget(app(sample));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('card'), findsOneWidget);
    });

    testWidgets('$name palette renders a full notice screen', (tester) async {
      DayawColors.dark = dark;
      await tester.pumpWidget(
        app(const LegalScreen(document: LegalDocument.privacy)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  test('the palette follows the dark flag', () {
    DayawColors.dark = false;
    final lightBg = DayawColors.bg;
    final lightText = DayawColors.text;
    DayawColors.dark = true;
    expect(DayawColors.bg, isNot(lightBg));
    expect(DayawColors.text, isNot(lightText));
    // The brand pair never changes.
    expect(DayawColors.sun, const Color(0xFFF2C230));
    expect(DayawColors.charcoal, const Color(0xFF1E1C19));
  });

  test('the light ground is a dirty white, not pure white', () {
    DayawColors.dark = false;
    expect(DayawColors.bg, isNot(Colors.white));
    expect(DayawColors.surface, isNot(Colors.white));
  });

  testWidgets('switching theme repaints the app live', (tester) async {
    AppSettings.instance.theme = 'light';
    await tester.pumpWidget(const DayawApp());
    await tester.pump();
    expect(DayawColors.dark, isFalse);
    AppSettings.instance.theme = 'dark';
    await tester.pump();
    expect(DayawColors.dark, isTrue);
    AppSettings.instance.theme = 'light';
    await tester.pump();
    expect(DayawColors.dark, isFalse);
    // Let the intro's timers and loops wind down.
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
  });
}
