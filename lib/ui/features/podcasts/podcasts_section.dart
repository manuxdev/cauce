import 'dart:async';

import 'package:flutter/material.dart';

import '../../../src/rust/api/player.dart' as core;
import '../../core/artwork.dart';
import '../../core/error_text.dart';
import '../../core/icons.dart';
import '../../core/l10n.dart';
import '../../core/motion.dart';
import '../../core/service_picker.dart';
import '../../core/skeleton.dart';
import '../../core/status_band.dart';
import '../../core/theme.dart';
import '../../core/toast.dart';
import '../../core/widgets.dart';
import '../player/view_models/player_view_model.dart';
import 'podcast_screen.dart';

/// The source episodes play through.
const podcastSource = 'podcast';

/// Whether `track` is a podcast episode: resumed where it was left, downloaded on its own, never
/// scrobbled, hearted, put in a playlist or looked up for lyrics.
bool isEpisode(core.TrackItem? track) => track?.source == podcastSource;

/// The feed address the listener typed, with https added when it names no scheme, or nothing
/// when it is not a web address.
String? feedAddress(String typed) {
  final text = typed.trim();
  if (text.isEmpty || text.contains(RegExp(r'\s'))) return null;
  final scheme = RegExp(r'^([a-zA-Z][a-zA-Z0-9+.-]*)://').firstMatch(text)?.group(1)?.toLowerCase();
  if (scheme != null && scheme != 'http' && scheme != 'https') return null;
  final address = scheme == null ? 'https://$text' : text;
  final host = Uri.tryParse(address)?.host ?? '';
  return host.contains('.') ? address : null;
}

/// How far into an episode the listener got, from 0 to 1, while it is under way.
double? episodeProgress({required BigInt durationMs, required BigInt positionMs, required bool played}) {
  if (played || durationMs == BigInt.zero || positionMs == BigInt.zero) return null;
  return (positionMs.toDouble() / durationMs.toDouble()).clamp(0.0, 1.0);
}

/// What is left of an episode under way.
Duration? episodeLeft({required BigInt durationMs, required BigInt positionMs, required bool played}) {
  if (episodeProgress(durationMs: durationMs, positionMs: positionMs, played: played) == null) return null;
  return Duration(milliseconds: (durationMs - positionMs).toInt());
}

/// "21 Oct", or "2 Mar 2024" for another year, with `months` as the language names them.
String episodeDate(int? publishedSecs, DateTime now, List<String> months) {
  if (publishedSecs == null) return '';
  final date = DateTime.fromMillisecondsSinceEpoch(publishedSecs * 1000);
  final day = '${date.day} ${months[date.month - 1]}';
  return date.year == now.year ? day : '$day ${date.year}';
}

const _debounce = Duration(milliseconds: 350);

/// The library's podcasts: the shows subscribed to, or the directory's answer to what is typed,
/// and a way to add any show by its feed's address.
class PodcastsSection extends StatefulWidget {
  const PodcastsSection({super.key, required this.player});

  final PlayerViewModel player;

  @override
  State<PodcastsSection> createState() => _PodcastsSectionState();
}

class _PodcastsSectionState extends State<PodcastsSection> {
  final _query = TextEditingController();
  Timer? _pending;
  late Future<List<core.PodcastShow>> _subscriptions = core.podcastSubscriptions();
  Future<List<core.PodcastShow>>? _found;

  @override
  void dispose() {
    _pending?.cancel();
    _query.dispose();
    super.dispose();
  }

  void _search() {
    final term = _query.text.trim();
    setState(() => _found = term.isEmpty ? null : core.podcastSearch(term: term));
  }

  /// Searches once the typing stops, as the music search does.
  void _typed(String text) {
    _pending?.cancel();
    _pending = Timer(text.trim().isEmpty ? Duration.zero : _debounce, () {
      if (mounted) _search();
    });
  }

  Future<void> _open(String feedUrl, {core.PodcastShow? show}) async {
    FocusScope.of(context).unfocus();
    await Navigator.of(context).push(
      CoverRoute<void>(
        builder: (context) => PodcastScreen(feedUrl: feedUrl, show: show, player: widget.player),
      ),
    );
    // Subscribing or not happens on the page.
    if (mounted) setState(() => _subscriptions = core.podcastSubscriptions());
  }

  Future<void> _addByAddress() async {
    final field = TextEditingController();
    final typed = await showDialog<String>(
      context: context,
      builder: (dialog) => AlertDialog(
        backgroundColor: CauceColors.sheet,
        title: Text(context.t('podcasts.add')),
        content: TextField(
          controller: field,
          autofocus: true,
          keyboardType: TextInputType.url,
          autocorrect: false,
          decoration: const InputDecoration(hintText: 'https://example.com/feed.xml'),
          onSubmitted: (text) => Navigator.of(dialog).pop(text),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialog).pop(), child: Text(context.t('search.cancel'))),
          TextButton(
            onPressed: () => Navigator.of(dialog).pop(field.text),
            child: Text(context.t('podcasts.addAction')),
          ),
        ],
      ),
    );
    field.dispose();
    if (typed == null || typed.trim().isEmpty || !mounted) return;
    final address = feedAddress(typed);
    if (address == null) {
      showToast(Toast(title: context.t('podcasts.badUrl'), tone: ToastTone.error));
      return;
    }
    _open(address);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: online,
      builder: (context, _) {
        final searching = online.value && _query.text.trim().isNotEmpty;
        return RefreshIndicator(
          color: CauceColors.foreground,
          onRefresh: () async {
            setState(() => _subscriptions = core.podcastSubscriptions());
            if (searching) _search();
            await Future.wait([_subscriptions, ?_found]);
          },
          child: ListView(
            padding: const EdgeInsets.only(bottom: bottomChromeInset),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            children: [
              if (online.value)
                _field(context)
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 4, CauceMetrics.gutter, 0),
                  child: Text(
                    context.t('podcasts.offline'),
                    style: TextStyle(fontSize: 14, color: CauceColors.mutedForeground),
                  ),
                ),
              if (searching) ...[
                SectionHeader(context.t('podcasts.found')),
                _shows(_found, empty: context.t('podcasts.none')),
              ] else ...[
                SectionHeader(context.t('podcasts.subscriptions')),
                _shows(_subscriptions, empty: context.t('podcasts.noSubscriptions'), help: context.t('podcasts.empty')),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _shows(Future<List<core.PodcastShow>>? shows, {required String empty, String? help}) {
    return FutureBuilder(
      future: shows,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) return const TrackListSkeleton();
        if (snapshot.hasError) {
          return EmptyState(
            glyph: CauceGlyph.alert,
            badge: true,
            danger: true,
            title: context.t('common.error'),
            message: explainError(snapshot.error!),
            actions: [FilledButton(onPressed: _search, child: Text(context.t('common.retry')))],
          );
        }
        final found = snapshot.data ?? const <core.PodcastShow>[];
        if (found.isEmpty) {
          return Padding(
            padding: const EdgeInsets.only(top: 40),
            child: EmptyState(glyph: CauceGlyph.headphones, title: empty, message: help),
          );
        }
        return Column(
          children: [
            for (final show in found)
              ShowTile(
                show: show,
                onTap: () => _open(show.feedUrl, show: show),
              ),
          ],
        );
      },
    );
  }

  Widget _field(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(CauceMetrics.gutter, 0, CauceMetrics.gutter, 4),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 42,
              child: TextField(
                controller: _query,
                textInputAction: TextInputAction.search,
                onChanged: _typed,
                onSubmitted: (_) {
                  _pending?.cancel();
                  _search();
                },
                style: const TextStyle(fontSize: 17),
                decoration: InputDecoration(
                  hintText: context.t('podcasts.search'),
                  prefixIcon: Padding(
                    padding: const EdgeInsets.only(left: 12, right: 8),
                    child: CauceIcon(CauceGlyph.search, size: 19, color: CauceColors.mutedForeground, weight: 2.1),
                  ),
                  prefixIconConstraints: const BoxConstraints(minWidth: 0, minHeight: 0),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Material(
            color: CauceColors.secondary,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _addByAddress,
              child: SizedBox.square(
                dimension: 42,
                child: Center(
                  child: Semantics(
                    label: context.t('podcasts.add'),
                    child: CauceIcon(CauceGlyph.plus, size: 20, weight: 2.1, color: CauceColors.foreground),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One show in a list: its artwork, title and author.
class ShowTile extends StatelessWidget {
  const ShowTile({super.key, required this.show, required this.onTap});

  final core.PodcastShow show;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 7, 16, 7),
        child: Row(
          children: [
            Artwork(url: show.artwork, size: 52, radius: 10),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    show.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, height: 1.25, fontWeight: FontWeight.w500),
                  ),
                  if (show.author.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(
                      show.author,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, height: 1.25, color: CauceColors.mutedForeground),
                    ),
                  ],
                ],
              ),
            ),
            CauceIcon(CauceGlyph.chevronRight, size: 18, color: CauceColors.mutedForeground),
          ],
        ),
      ),
    );
  }
}
