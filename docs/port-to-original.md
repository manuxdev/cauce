# Port to original

Features built on `dev` that should later go to the `original` branch as well. Port them only when asked, and keep
what makes `original` special: its providers, their sign-in flows and their provider features.

Store-only commits (removing providers or lyrics sources, the bundle id, store copy) never go to `original`.

| Commit | Feature | Notes |
|---|---|---|
| `f6e7732` | Play next, add to queue, queue saved at once, scrolling track options sheet | Touches the bridge, so regenerate it with `flutter_rust_bridge_codegen generate` after porting. The track options sheet in `original` also has its provider rows |
| `7097bdf` | Lyrics from the Subsonic server: `SubsonicLyrics` registered as the `server` lyrics group, default order `lrc`, `server`, `lrclib`, and saved orders without `server` get it at its default place | `original`'s lyrics groups also include `provider`, so merge the default order there (`lyricsSourceGroups` in `app_prefs.dart` and `GROUPS` in `lyrics_shelf.rs`) rather than taking this one as is |
| `6939923` | Lyrics sources can be turned off: a switch on each row of the lyrics source list, kept as `lyricsSourcesOff` in `app.json` (unknown names ignored, missing key means all on), Dart sends only the sources left on (`askedLyricsSources`), and Rust's `search_lyrics` asks only the services in the groups it is given | `original` also has the `provider` group; it gets a switch the same way, with no extra change, since it is in `lyricsSourceGroups` and `GROUPS` |
