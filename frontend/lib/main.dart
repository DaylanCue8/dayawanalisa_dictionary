import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
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

class DayawApp extends StatefulWidget {
  const DayawApp({super.key});

  @override
  State<DayawApp> createState() => _DayawAppState();
}

class _DayawAppState extends State<DayawApp> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    AppSettings.instance.themeNotifier.addListener(_applyTheme);
    DayawColors.dark = _resolveDark();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    AppSettings.instance.themeNotifier.removeListener(_applyTheme);
    super.dispose();
  }

  // The device switched light/dark: matters when the theme is System.
  @override
  void didChangePlatformBrightness() => _applyTheme();

  bool _resolveDark() => switch (DayawTheme.current) {
    DayawTheme.light => false,
    DayawTheme.dark => true,
    DayawTheme.system =>
      WidgetsBinding.instance.platformDispatcher.platformBrightness ==
          Brightness.dark,
  };

  /// Applies the palette and rebuilds every widget in place. Screens read
  /// the palette's getters directly, so they all need to rebuild; marking
  /// elements dirty keeps their state (scroll, text, results) intact.
  void _applyTheme() {
    final dark = _resolveDark();
    if (dark == DayawColors.dark) return;
    setState(() => DayawColors.dark = dark);
    void rebuild(Element element) {
      element.markNeedsBuild();
      element.visitChildren(rebuild);
    }

    (context as Element).visitChildren(rebuild);
  }

  ThemeData _themeData() {
    final dark = DayawColors.dark;
    final scheme = ColorScheme.fromSeed(
      seedColor: DayawColors.sun,
      brightness: dark ? Brightness.dark : Brightness.light,
    ).copyWith(
      primary: dark ? DayawColors.sun : DayawColors.charcoal,
      onPrimary: dark ? DayawColors.charcoal : DayawColors.sun,
      secondary: DayawColors.sun,
      onSecondary: DayawColors.charcoal,
      surface: DayawColors.bg,
      onSurface: DayawColors.text,
      error: DayawColors.brick,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: DayawColors.bg,
      canvasColor: DayawColors.bg,
      dividerColor: DayawColors.line,
      iconTheme: IconThemeData(color: DayawColors.text),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: DayawColors.amber,
        selectionColor: DayawColors.sun.withValues(alpha: 0.35),
        selectionHandleColor: DayawColors.amber,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: DayawColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: DayawColors.surface,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: DayawColors.charcoal,
        contentTextStyle: const TextStyle(color: Color(0xFFEFE9DD)),
        actionTextColor: DayawColors.sun,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? DayawColors.charcoal
              : DayawColors.surface,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? DayawColors.sun
              : DayawColors.well,
        ),
        trackOutlineColor: WidgetStatePropertyAll(DayawColors.line),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: DayawColors.sun,
        inactiveTrackColor: DayawColors.well,
        thumbColor: DayawColors.amber,
        overlayColor: DayawColors.sun.withValues(alpha: 0.15),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: DayawColors.amber,
        linearTrackColor: DayawColors.well,
      ),
      // iOS slide-in (with swipe-back from the left edge) on every
      // platform, for every MaterialPageRoute in the app.
      pageTransitionsTheme: PageTransitionsTheme(
        builders: {
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.windows: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.linux: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }

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
      theme: _themeData(),
      // First launch shows the intro; after that, straight to the app.
      home: AppSettings.instance.hasSeenIntro
          ? const DayawLandingScreen()
          : const IntroScreen(),
    );
  }
}