import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'screens/dayaw_landing_screen.dart';
import 'screens/intro_screen.dart';
import 'services/app_language.dart';
import 'services/app_settings.dart'; // Import the file you just created
import 'widgets/dayaw_style.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await AppSettings.instance.load();
  runApp(const DayawApp());
}

/// iOS-style bouncy scrolling on every platform, and lets a mouse drag
/// scroll too (handy on desktop/web builds).
class _BouncyScrollBehavior extends MaterialScrollBehavior {
  const _BouncyScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Set<PointerDeviceKind> get dragDevices => {
    PointerDeviceKind.touch,
    PointerDeviceKind.mouse,
    PointerDeviceKind.trackpad,
    PointerDeviceKind.stylus,
  };
}

class DayawApp extends StatelessWidget {
  const DayawApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Dayaw',
      scrollBehavior: const _BouncyScrollBehavior(),
      // Every route, dialog and sheet sits under this, so text switches
      // language live.
      builder: (context, child) =>
          ThemeScope(child: LanguageScope(child: child!)),
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: Colors.brown,
        // iOS slide-in (with swipe-back from the left edge) on every
        // platform, for every MaterialPageRoute in the app.
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: {
            TargetPlatform.android: CupertinoPageTransitionsBuilder(),
            TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
            TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
            TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
          },
        ),
      ),
      // First launch shows the intro; after that, straight to the app.
      home: AppSettings.instance.hasSeenIntro
          ? const DayawLandingScreen()
          : const IntroScreen(),
    );
  }
}
