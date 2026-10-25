import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../../src/rust/api/player.dart' as core;
import '../../../core/app_prefs.dart';
import '../../../core/icons.dart';
import '../../../core/l10n.dart';
import '../../../core/motion.dart';
import '../../../core/theme.dart';
import '../../player/view_models/player_view_model.dart';
import '../view_models/lyrics_view_model.dart';

/// How lit a line or word is before it is sung.
const _unsung = 0.38;

/// How the lyrics are set, after the player's design: as the listener sets them, centred round
/// the vinyl, large and left like a poster, as a prompter's timed rows on the tape, or centred
/// with a shadow over the immersive cover.
enum LyricsLook { standard, vinyl, poster, prompter, immersive }

/// The current track's lyrics. Synced lines follow playback, word-timed ones light up word by
/// word, and a tap on a line seeks there.
class LyricsPanel extends StatefulWidget {
  const LyricsPanel({super.key, required this.lyrics, required this.player, this.look = LyricsLook.standard});

  final LyricsViewModel lyrics;
  final PlayerViewModel player;
  final LyricsLook look;

  @override
  State<LyricsPanel> createState() => _LyricsPanelState();
}

class _LyricsPanelState extends State<LyricsPanel> with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => _tick());
  final _scroll = ScrollController();
  List<GlobalKey> _keys = [];
  core.LyricsView? _shown;
  int? _active;

  /// Following waits until then after the user scrolls the lyrics themselves.
  DateTime _heldUntil = DateTime(0);

  /// The engine's last reported position and when it arrived, which the ticker runs on from.
  Duration _reported = Duration.zero;
  DateTime _reportedAt = DateTime.now();
  Duration _now = Duration.zero;

  @override
  void initState() {
    super.initState();
    widget.player.addListener(_report);
    _report();
    _ticker.start();
  }

  @override
  void dispose() {
    widget.player.removeListener(_report);
    _ticker.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _report() {
    _reported = widget.player.position;
    _reportedAt = DateTime.now();
  }

  void _tick() {
    final running = widget.player.playing ? DateTime.now().difference(_reportedAt) : Duration.zero;
    // The listener's offset moves the lyrics against the music.
    final now = _reported + running - appPrefs.lyricsOffset;
    final lyrics = _shown;
    if (lyrics == null || !lyrics.synced) return;
    final active = _activeLine(lyrics.lines, now);
    setState(() => _now = now);
    if (active != _active) {
      _active = active;
      _follow(active);
    }
  }

  /// Keeps the sung line a third of the way down.
  void _follow(int? index, {bool retried = false}) {
    if (index == null || index >= _keys.length || DateTime.now().isBefore(_heldUntil)) return;
    final context = _keys[index].currentContext;
    if (context == null) {
      // Lyrics that just arrived are not laid out yet; follow once they are.
      if (!retried) SchedulerBinding.instance.addPostFrameCallback((_) => _follow(index, retried: true));
      return;
    }
    Scrollable.ensureVisible(
      context,
      alignment: 0.33,
      duration: const Duration(milliseconds: 450),
      curve: CauceCurves.soft,
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.lyrics,
      builder: (context, _) {
        final lyrics = widget.lyrics.lyrics;
        if (!identical(lyrics, _shown)) {
          _shown = lyrics;
          _active = null;
          _keys = [for (final _ in lyrics?.lines ?? const []) GlobalKey()];
        }
        if (lyrics == null) {
          return Center(
            child: widget.lyrics.loading
                ? const CircularProgressIndicator()
                : Text(context.t('lyrics.none'), style: TextStyle(color: CauceColors.dark.mutedForeground)),
          );
        }
        return ShaderMask(
          shaderCallback: (bounds) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.transparent, Colors.white, Colors.white, Colors.transparent],
            stops: [0, 0.08, 0.88, 1],
          ).createShader(bounds),
          blendMode: BlendMode.dstIn,
          child: NotificationListener<UserScrollNotification>(
            onNotification: (_) {
              _heldUntil = DateTime.now().add(const Duration(seconds: 3));
              return false;
            },
            // Every line is built, not only the visible ones: following the sung line needs its
            // context, and a lazy list has none for a line scrolled out of view.
            child: SingleChildScrollView(
              controller: _scroll,
              padding: EdgeInsets.symmetric(vertical: widget.look == LyricsLook.prompter ? 60 : 120),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [for (var index = 0; index < lyrics.lines.length; index++) _line(lyrics, index)],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _line(core.LyricsView lyrics, int index) {
    final line = lyrics.lines[index];
    final active = lyrics.synced && index == _active;
    final look = widget.look;
    final centered = switch (look) {
      LyricsLook.standard => appPrefs.lyricsCentered,
      LyricsLook.vinyl || LyricsLook.immersive => true,
      LyricsLook.poster || LyricsLook.prompter => false,
    };
    final align = centered ? TextAlign.center : TextAlign.start;
    // Synced, the line being sung is drawn larger than the rest, which are scaled down from it.
    final size = switch (look) {
      LyricsLook.standard => lyrics.synced ? 31.0 : 24.0,
      LyricsLook.vinyl => 24.0,
      LyricsLook.poster => 33.0,
      LyricsLook.prompter => 18.0,
      LyricsLook.immersive => 27.0,
    };
    final style = TextStyle(
      fontFamily: look == LyricsLook.prompter ? null : displayFont,
      fontSize: size * appPrefs.lyricsScale,
      fontWeight: look == LyricsLook.prompter ? FontWeight.w600 : FontWeight.w700,
      height: look == LyricsLook.poster ? 1.02 : 1.25,
      letterSpacing: look == LyricsLook.poster ? -1 : -0.4,
      shadows: look == LyricsLook.immersive
          ? const [Shadow(color: Color(0x66000000), blurRadius: 12, offset: Offset(0, 2))]
          : null,
    );
    final words = line.words;
    final Widget text = active && words.isNotEmpty && appPrefs.wordByWord
        ? Text.rich(
            TextSpan(
              children: [
                for (final word in words)
                  TextSpan(
                    text: word.text,
                    style: style.copyWith(color: CauceColors.dark.foreground.withValues(alpha: _wordLight(word))),
                  ),
              ],
            ),
            textAlign: align,
          )
        : AnimatedDefaultTextStyle(
            duration: const Duration(milliseconds: 240),
            style: style.copyWith(
              color: CauceColors.dark.foreground.withValues(alpha: !lyrics.synced || active ? 1 : _unsung),
            ),
            child: Text(line.text.isEmpty ? '♪' : line.text, textAlign: align),
          );
    return GestureDetector(
      key: _keys[index],
      behavior: HitTestBehavior.opaque,
      // A tap jumps to the line and picks up following again.
      onTap: lyrics.synced
          ? () {
              _heldUntil = DateTime(0);
              widget.player.seek(Duration(milliseconds: line.startMs.toInt()) + appPrefs.lyricsOffset);
            }
          : null,
      child: look == LyricsLook.prompter
          ? _prompterRow(line, active, lyrics.synced, text)
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
              child: AnimatedScale(
                scale: !lyrics.synced || active ? 1 : 0.78,
                alignment: centered ? Alignment.center : Alignment.centerLeft,
                duration: const Duration(milliseconds: 520),
                curve: CauceCurves.soft,
                child: text,
              ),
            ),
    );
  }

  /// A prompter's row: when the line starts, then the line, the sung one on an accent band
  /// with a marker.
  Widget _prompterRow(core.LyricLine line, bool active, bool synced, Widget text) {
    final accent = CauceColors.dark.accent;
    final at = Duration(milliseconds: line.startMs.toInt());
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      constraints: const BoxConstraints(minHeight: 46),
      margin: const EdgeInsets.symmetric(horizontal: 14, vertical: 1),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: active ? accent.withValues(alpha: 0.15) : Colors.transparent,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 30,
            child: active
                ? Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: CauceIcon(CauceGlyph.play, size: 22, color: accent),
                  )
                : null,
          ),
          SizedBox(
            width: 50,
            child: synced
                ? Text(
                    formatDuration(at),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      height: 1.7,
                      color: active ? accent : const Color(0x80FFFFFF),
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  )
                : null,
          ),
          Expanded(child: text),
        ],
      ),
    );
  }

  /// A word fades up from unsung to fully lit across the time it is sung.
  double _wordLight(core.LyricWord word) {
    final start = word.startMs.toInt();
    final end = word.endMs.toInt();
    final now = _now.inMilliseconds;
    if (now >= end) return 1;
    if (now <= start || end <= start) return _unsung;
    return _unsung + (1 - _unsung) * (now - start) / (end - start);
  }
}

/// The line being sung at `now`: the last one started.
int? _activeLine(List<core.LyricLine> lines, Duration now) {
  final millis = now.inMilliseconds;
  int? active;
  for (final (index, line) in lines.indexed) {
    if (line.startMs.toInt() > millis) break;
    active = index;
  }
  return active;
}
