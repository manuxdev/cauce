import 'package:flutter/widgets.dart';

import '../features/accounts/view_models/accounts_view_model.dart';
import '../features/library/view_models/favorites_view_model.dart';
import '../features/lyrics/view_models/lyrics_view_model.dart';
import '../features/player/view_models/player_view_model.dart';
import '../features/settings/view_models/playback_settings_view_model.dart';

/// Hands the app-wide view models to every screen below it. They live as long as the app.
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.player,
    required this.accounts,
    required this.favorites,
    required this.lyrics,
    required this.playbackSettings,
    required super.child,
  });

  final PlayerViewModel player;
  final AccountsViewModel accounts;
  final FavoritesViewModel favorites;
  final LyricsViewModel lyrics;
  final PlaybackSettingsViewModel playbackSettings;

  static AppScope of(BuildContext context) => context.getInheritedWidgetOfExactType<AppScope>()!;

  @override
  bool updateShouldNotify(AppScope oldWidget) => false;
}
