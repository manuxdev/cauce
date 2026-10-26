import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cauce/src/rust/api/player.dart' as core;
import 'package:cauce/src/rust/frb_generated.dart';
import 'package:cauce/ui/core/app_prefs.dart';
import 'package:cauce/ui/core/app_scope.dart';
import 'package:cauce/ui/features/accounts/view_models/accounts_view_model.dart';
import 'package:cauce/ui/features/library/view_models/favorites_view_model.dart';
import 'package:cauce/ui/features/lyrics/view_models/lyrics_view_model.dart';
import 'package:cauce/ui/features/player/view_models/player_view_model.dart';
import 'package:cauce/ui/features/player/views/now_playing_screen.dart';
import 'package:cauce/ui/features/player/views/tape_design.dart';
import 'package:cauce/ui/features/settings/view_models/playback_settings_view_model.dart';
import 'package:cauce/ui/features/settings/views/player_design_screen.dart';

final _track = core.TrackItem(
  source: 'subsonic',
  id: '42',
  title: 'Mar de fondo',
  artists: 'Lucía Vega',
  album: 'Costa Norte',
  durationMs: BigInt.from(204000),
  playable: true,
  artistLinks: const [],
);

Future<PlayerViewModel> _playing(WidgetTester tester) async {
  final states = StreamController<core.PlayerSnapshot>.broadcast();
  final player = PlayerViewModel(states.stream);
  states.add(
    core.PlayerSnapshot(
      track: _track,
      index: 1,
      queue: [_track, _track],
      status: core.PlaybackStatus.paused,
      positionMs: BigInt.from(84000),
      durationMs: BigInt.from(204000),
      repeat: core.RepeatMode.all,
      stopsAfterCurrent: false,
      stalled: false,
    ),
  );
  await tester.pump();
  return player;
}

Widget _app(PlayerViewModel player, Widget child) => AppScope(
  player: player,
  accounts: AccountsViewModel(),
  favorites: FavoritesViewModel(),
  lyrics: LyricsViewModel(player),
  playbackSettings: PlaybackSettingsViewModel(),
  child: MaterialApp(home: child),
);

/// The core as far as the player's screens ask it: silence and nothing stored; anything else fails,
/// as it would offline.
class _Core implements RustLibApi {
  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName.toString();
    if (name.contains('Levels')) return Float32List(2);
    if (name.contains('EqualizerPresets')) return <core.EqualizerPreset>[];
    if (name.contains('Stored')) return false;
    if (name.contains('CacheGbRange')) return (1, 10);
    return Future<Never>.error(StateError('no core under test'));
  }
}

void main() {
  setUpAll(() => RustLib.initMock(api: _Core()));

  setUp(() {
    // The native volume and output views have no platform under test.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform_views,
      (call) async => call.method == 'create' ? 0 : null,
    );
  });

  for (final size in const [Size(390, 844), Size(375, 667)]) {
    for (final design in PlayerDesign.values) {
      for (final lyrics in [false, true]) {
        testWidgets('${design.name}${lyrics ? ' lyrics' : ''} lays out on a ${size.height.round()}-point phone', (
          tester,
        ) async {
          tester.view.physicalSize = size * 3;
          tester.view.devicePixelRatio = 3;
          addTearDown(tester.view.reset);
          appPrefs
            ..resetPlayerDesign()
            ..playerDesign = design;
          final player = await _playing(tester);
          await tester.pumpWidget(_app(player, NowPlayingScreen(player: player)));
          await tester.pump(const Duration(milliseconds: 600));
          if (lyrics) {
            final lyricsButton = find.byWidgetPredicate(
              (widget) =>
                  (widget is Text && widget.data?.toLowerCase() == 'lyrics') ||
                  (widget is Tooltip && widget.message == 'Lyrics') ||
                  (widget is Semantics && widget.properties.label?.toLowerCase() == 'lyrics'),
            );
            await tester.tap(lyricsButton.first);
            await tester.pump(const Duration(milliseconds: 600));
            expect(find.text('No lyrics for this track'), findsOneWidget);
          }
          expect(tester.takeException(), isNull);
          expect(find.byType(NowPlayingScreen), findsOneWidget);
          // The deck once ended under its keys, the screen behind showing below.
          if (design == PlayerDesign.tape) {
            expect(tester.getSize(find.byType(TapeDesign)), size);
            // The deck once sat as one block in the middle, a dark band above it: it fills the height.
            if (!lyrics) {
              expect(tester.getTopLeft(find.text('NOW PLAYING')).dy, lessThan(40));
              expect(tester.getBottomLeft(find.textContaining('HOLD')).dy, greaterThan(size.height - 40));
            }
          }
          await tester.pumpWidget(const SizedBox());
          await tester.pump(const Duration(seconds: 1));
        });
      }
    }
  }

  test('the tape names the bitrate in a few letters', () {
    expect(compactBitrate('AAC · 256 kbps'), '256K');
    expect(compactBitrate('Ogg Vorbis 320 kbps'), '320K');
    expect(compactBitrate('FLAC'), isNull);
    expect(compactBitrate(null), isNull);
  });

  testWidgets('the design settings lay out and pick a design', (tester) async {
    tester.view.physicalSize = const Size(390, 844) * 3;
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    appPrefs.resetPlayerDesign();
    final player = await _playing(tester);
    await tester.pumpWidget(_app(player, const PlayerDesignScreen()));
    await tester.pump();
    expect(tester.takeException(), isNull);
    // Every thumbnail fills its card, the vinyl's too, rather than shrinking to what it draws.
    for (final thumb in find.byWidgetPredicate((widget) => '${widget.runtimeType}' == '_Thumb').evaluate()) {
      expect((thumb.size!), anyOf(const Size(100, 178), const Size(112, 200), const Size(84, 150)));
    }
    await tester.tap(find.text('Vinyl'));
    await tester.pump();
    expect(appPrefs.playerDesign, PlayerDesign.vinyl);
    // The ring only goes round the vinyl: another design drops it for the design's own.
    await tester.ensureVisible(find.text('Ring'));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Ring'));
    await tester.pump();
    expect(appPrefs.seekStyle, SeekStyle.ring);
    await tester.scrollUntilVisible(find.text('Poster'), -300, scrollable: find.byType(Scrollable).first);
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Poster'));
    await tester.pump();
    expect(appPrefs.seekStyle, SeekStyle.auto);
    await tester.ensureVisible(find.text('Dots'));
    await tester.pump(const Duration(seconds: 1));
    await tester.tap(find.text('Dots'));
    await tester.pump();
    expect(appPrefs.seekStyle, SeekStyle.dots);
    appPrefs.resetPlayerDesign();
  });
}
