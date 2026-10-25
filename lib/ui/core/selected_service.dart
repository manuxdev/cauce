import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// The service the user picked last, on any screen, kept across launches: every screen opens on
/// it while it is one of that screen's choices.
class SelectedService extends ChangeNotifier {
  String? _slug;
  File? _file;

  Future<void> load() async {
    final file = File('${(await getApplicationSupportDirectory()).path}/selected_service');
    _file = file;
    if (await file.exists()) {
      _slug = (await file.readAsString()).trim();
      notifyListeners();
    }
  }

  /// The remembered service when it is among `choices`, the first choice otherwise.
  String? among(List<String> choices) {
    if (choices.isEmpty) return null;
    return choices.contains(_slug) ? _slug : choices.first;
  }

  void select(String slug) {
    if (slug == _slug) return;
    _slug = slug;
    notifyListeners();
    _file?.writeAsString(slug).ignore();
  }
}

final selectedService = SelectedService();
