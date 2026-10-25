import 'dart:io';
import 'dart:ui';

import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'strings.dart';

/// The languages the app speaks. `system` follows the phone's language, falling back to English.
enum AppLanguage {
  system('system'),
  english('en'),
  spanish('es');

  const AppLanguage(this.id);

  final String id;
}

/// The chosen language, kept across launches.
class Language extends ChangeNotifier {
  AppLanguage _chosen = AppLanguage.system;
  File? _file;

  AppLanguage get chosen => _chosen;

  /// The table strings are read from.
  Map<String, String> get table {
    final code = switch (_chosen) {
      AppLanguage.system => PlatformDispatcher.instance.locale.languageCode,
      _ => _chosen.id,
    };
    return code == 'es' ? spanish : english;
  }

  Future<void> load() async {
    final file = File('${(await getApplicationSupportDirectory()).path}/language');
    _file = file;
    if (!await file.exists()) return;
    final id = (await file.readAsString()).trim();
    _chosen = AppLanguage.values.firstWhere((language) => language.id == id, orElse: () => AppLanguage.system);
    notifyListeners();
  }

  void choose(AppLanguage language) {
    if (language == _chosen) return;
    _chosen = language;
    notifyListeners();
    _file?.writeAsString(language.id).ignore();
  }
}

final language = Language();

/// Puts [language] above the app, so every widget reading a string rebuilds when it changes.
class LanguageScope extends InheritedNotifier<Language> {
  LanguageScope({super.key, required super.child}) : super(notifier: language);
}

extension Translate on BuildContext {
  /// The string for `key` in the chosen language, `{name}` placeholders filled from `args`.
  /// A key missing from the table reads as English, then as the key itself.
  String t(String key, [Map<String, Object> args = const {}]) =>
      _fill(dependOnInheritedWidgetOfExactType<LanguageScope>()?.notifier?.table ?? english, key, args);
}

/// [Translate.t] for code with no widget at hand.
String translate(String key, [Map<String, Object> args = const {}]) => _fill(language.table, key, args);

String _fill(Map<String, String> table, String key, Map<String, Object> args) {
  var text = table[key] ?? english[key] ?? key;
  for (final MapEntry(:key, :value) in args.entries) {
    text = text.replaceAll('{$key}', '$value');
  }
  return text;
}
