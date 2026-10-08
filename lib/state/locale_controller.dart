// Locale controller — the user's language override (or "System default").
// Persisted on-device via SharedPreferences, mirroring ThemeController /
// UnitsController. Null means follow the OS locale.

import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../l10n/app_localizations.dart';

class LocaleController extends ChangeNotifier {
  static const String _kLocale = 'locale_override'; // language code, e.g. 'es'

  String? _code;
  LocaleController._(this._code);

  factory LocaleController.seed(String? code) => LocaleController._(code);

  static Future<LocaleController> bootstrap() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_kLocale);
    // A locale dropped from AppLocalizations.supportedLocales (or from a
    // stale build) has no row in the picker — fall back to system default
    // rather than showing a selection nothing matches.
    final code = AppLocalizations.supportedLocales
            .any((l) => l.languageCode == stored)
        ? stored
        : null;
    return LocaleController._(code);
  }

  /// Resolve app copy without a widget context (for OS notifications).
  /// The saved override wins; otherwise use the same supported-language
  /// fallback as MaterialApp. Nothing is written by this read.
  static Future<AppLocalizations> presentationLocalizations() async {
    String? stored;
    try {
      stored = (await SharedPreferences.getInstance()).getString(_kLocale);
    } catch (_) {}
    final supported = AppLocalizations.supportedLocales;
    if (stored != null && supported.any((l) => l.languageCode == stored)) {
      return lookupAppLocalizations(Locale(stored));
    }
    for (final locale in PlatformDispatcher.instance.locales) {
      if (supported.any((l) => l.languageCode == locale.languageCode)) {
        return lookupAppLocalizations(Locale(locale.languageCode));
      }
    }
    return lookupAppLocalizations(const Locale('en'));
  }

  /// null = system default.
  String? get code => _code;
  Locale? get locale => _code == null ? null : Locale(_code!);

  Future<void> setCode(String? code) async {
    if (_code == code) return;
    _code = code;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    if (code == null) {
      await prefs.remove(_kLocale);
    } else {
      await prefs.setString(_kLocale, code);
    }
  }
}
