// Every theme (Gradient, Bold, Embroidery) must render the shared pieces
// without errors, and switching theme must repaint them live.
import 'package:dayaw/screens/legal_screen.dart';
import 'package:dayaw/services/app_language.dart';
import 'package:dayaw/services/app_settings.dart';
import 'package:dayaw/widgets/dayaw_style.dart';
import 'package:dayaw/widgets/embroidery.dart';
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
        GlassContainer(padding: EdgeInsets.all(3), child: Text('tight')),
        SizedBox(height: 56, child: GlassBar(child: SizedBox.expand())),
      ],
    ),
  ),
);

void main() {
  tearDown(() => AppSettings.instance.theme = 'gradient');

  for (final theme in DayawTheme.values) {
    testWidgets('${theme.name} renders the shared widgets', (tester) async {
      AppSettings.instance.theme = theme.name;
      await tester.pumpWidget(app(sample));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('card'), findsOneWidget);
      final stitched = find.byType(CrossStitchBand);
      expect(
        stitched,
        theme == DayawTheme.embroidery ? findsOneWidget : findsNothing,
      );
    });

    testWidgets('${theme.name} renders a full notice screen', (tester) async {
      AppSettings.instance.theme = theme.name;
      await tester.pumpWidget(
        app(const LegalScreen(document: LegalDocument.privacy)),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('switching theme repaints live', (tester) async {
    AppSettings.instance.theme = 'gradient';
    await tester.pumpWidget(app(sample));
    expect(find.byType(CrossStitchBand), findsNothing);
    AppSettings.instance.theme = 'embroidery';
    await tester.pump();
    expect(find.byType(CrossStitchBand), findsOneWidget);
    AppSettings.instance.theme = 'bold';
    await tester.pump();
    expect(find.byType(CrossStitchBand), findsNothing);
  });

  test('themedGradient only returns the gradient in the Gradient theme', () {
    const g = LinearGradient(colors: [Colors.red, Colors.blue]);
    AppSettings.instance.theme = 'gradient';
    expect(themedGradient(g), g);
    AppSettings.instance.theme = 'bold';
    expect(themedGradient(g), isNull);
    AppSettings.instance.theme = 'embroidery';
    expect(themedGradient(g), isNull);
  });

  test('thread color contrasts with the fabric', () {
    expect(Thread.on(Colors.white), Thread.brown);
    expect(Thread.on(Colors.black), Thread.light);
  });
}
