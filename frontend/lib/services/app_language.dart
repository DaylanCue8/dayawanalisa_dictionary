import 'package:flutter/widgets.dart';

import 'app_settings.dart';

/// The two languages the app's text comes in.
const List<(String code, String name)> appLanguages = [
  ('en', 'English'),
  ('fil', 'Filipino'),
];

/// Sits above every screen (see DayawApp's builder). Widgets that read
/// text through [LanguageContext.tr] depend on it, so switching language
/// rebuilds them instantly - even under const parents - without losing
/// any screen's state.
class LanguageScope extends InheritedNotifier<ValueNotifier<String>> {
  LanguageScope({super.key, required super.child})
    : super(notifier: AppSettings.instance.languageNotifier);
}

extension LanguageContext on BuildContext {
  /// Picks the English or Filipino text for the current language, and
  /// rebuilds this widget whenever the language changes. Use it in build
  /// methods; use the top-level [tr] in callbacks and background code.
  String tr(String en, String fil) {
    dependOnInheritedWidgetOfExactType<LanguageScope>();
    return _pick(en, fil);
  }
}

/// Same as [LanguageContext.tr] but without a BuildContext - for
/// snackbars shown after an await, exports, and other non-build code.
String tr(String en, String fil) => _pick(en, fil);

String _pick(String en, String fil) =>
    AppSettings.instance.language == 'fil' ? fil : en;
