import '../../../src/rust/api/player.dart' as core;

/// The covers of the upcoming tracks the core prefetches, to keep them with the audio so they
/// show offline too: as many as it fetches (`Transport::prefetch`), two on Wi-Fi, one on mobile
/// data and none saving data on it, offline or with nothing playing. Only those fetched over the
/// network; a file's cover is already on the phone.
List<String> upcomingCovers(
  List<core.TrackItem> queue,
  int? index, {
  required core.RepeatMode repeat,
  required bool online,
  required bool cellular,
  required bool dataSaver,
}) {
  if (index == null || !online || (cellular && dataSaver)) return const [];
  final depth = cellular ? 1 : 2;
  final length = queue.length;
  final wraps = repeat == core.RepeatMode.all;
  return [
    for (var at = index + 1; at < index + length && at <= index + depth && (wraps || at < length); at++)
      ?queue[at % length].cover,
  ].where((cover) => cover.startsWith('http')).toList();
}
