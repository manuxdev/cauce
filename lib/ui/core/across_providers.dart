import '../../src/rust/api/player.dart' as core;

/// One from each list in turn, so no provider's results bury another's.
List<T> interleave<T>(List<List<T>> lists) => [
  for (var rank = 0; lists.any((list) => rank < list.length); rank++)
    for (final list in lists)
      if (rank < list.length) list[rank],
];

/// `slugs` in the order the user keeps, the ones it does not name after, as they came.
List<String> ordered(List<String> slugs, List<String> order) => [
  for (final slug in order)
    if (slugs.contains(slug)) slug,
  for (final slug in slugs)
    if (!order.contains(slug)) slug,
];

/// The first playable track in `found` that is `wanted`: the same title, give or take an
/// edition such as "Remastered", by the same first artist.
core.TrackItem? sameSong(core.TrackItem wanted, List<core.TrackItem> found) {
  final title = _bare(wanted.title);
  final artist = _firstArtist(wanted.artists);
  for (final track in found) {
    if (track.playable && _bare(track.title) == title && _firstArtist(track.artists) == artist) return track;
  }
  return null;
}

/// The title without what follows a dash or opens a bracket, lowercased.
String _bare(String title) => title.split(RegExp(r' - |\(|\[')).first.trim().toLowerCase();

String _firstArtist(String artists) => artists.split(RegExp(r',|&| feat\.? | ft\.? ')).first.trim().toLowerCase();
