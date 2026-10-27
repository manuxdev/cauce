# Roadmap

Improvements for the store version of Cauce, to build one at a time.

The store version only uses legitimate sources: files on the device, the user's own servers, open catalogs and official
APIs. Unofficial access to commercial streaming services stays out of it.

Already in the app: equalizer, player designs (immersive, wave, tape, poster), cover tint, lyrics, scrobbling, sleep
timer, gapless playback, volume normalization, Subsonic/Navidrome with downloads.

## Sources

- [ ] Jellyfin
- [ ] Plex
- [ ] Network and cloud folders: WebDAV, SMB, Google Drive, Dropbox, iCloud Drive
- [ ] Internet radio through Radio Browser (open catalog)
- [ ] Podcasts through RSS
- [ ] Apple Music through official MusicKit (needs the paid Apple Developer Program)

## System integration

- [ ] CarPlay (needs Apple's CarPlay audio entitlement) and Android Auto
- [ ] Home screen and lock screen widgets
- [ ] Chromecast

## Display

- [ ] Landscape layout: every screen works and uses the width well when the phone is turned
- [ ] Rest mode: a low-power landscape player for when the phone sits docked or charging. Dark, few redraws, dimmed,
      no spectrum or heavy effects, and large enough to read from a distance

## Pro candidates

- [ ] More player designs and themes
- [ ] Listening stats and a yearly recap, built from local history with no server
- [ ] Smart playlists (most played this month, not played in six months, and so on)
- [ ] Tag and cover editor with MusicBrainz and Cover Art Archive
- [ ] Crossfade between tracks

## Subscription candidate

- [ ] Sync playlists, settings and history across devices

## Community requests

From the most-reacted issues of similar open-source players, the Symfonium forum, the Jellyfin feature board and Lemmy
(October 2026). Reddit could not be read; X is covered in its own section below. Numbers are reactions or votes.
Check each one against what Cauce already does before starting it.

### Library and offline

- [x] Offline-first mode. Strongest single ask (Feishin #47, 88). https://github.com/jeffvli/feishin/issues/47
      Done: played-songs cache with a size limit and LRU eviction, the storage screen, preload of the next track,
      offline detection. Added: likes already made download too once "download likes" is on, and downloaded albums
      and playlists stay kept, fetching the tracks they gain, and a manual offline mode (only kept tracks and files
      play, nothing downloads or syncs), and a per-item downloads list in storage, by kept collection with sizes on
      disk, deleting a group or a track, and prefetching more than one track: the next two on Wi-Fi go into the
      cache once the current one is in, so they also play offline.
- [ ] Several artists and genres per track (OpenSubsonic fields, custom separators). Navidrome #238 (50), Gramophone's
      top ask. https://github.com/navidrome/navidrome/issues?q=is%3Aissue+sort%3Areactions-%2B1-desc
- [ ] Playlist management: M3U import and export, folder to playlist, playlist folders, custom covers, sorting, add a
      whole album or artist. Navidrome #406 (44). https://github.com/OxygenCobalt/Auxio/issues?q=is%3Aissue+sort%3Areactions-%2B1-desc
- [ ] Ratings and likes: star ratings, a virtual "Liked" playlist, Last.fm love sync, skip disliked songs. Finamp #133
      (16). https://github.com/finamp-app/finamp/issues?q=is%3Aissue+sort%3Areactions-%2B1-desc
- [ ] Browse a server library by folder, not only by tags. Navidrome #1380 (18).
      https://github.com/supersonic-app/supersonic/issues?q=is%3Aissue+sort%3Areactions-%2B1-desc
- [ ] Release types and editions: albums, EPs, singles, compilations, disc headers, several editions of one album, a
      composer view. Navidrome #369 (15), #275 (17); Jellyfin "multiple versions" (66).
- [ ] One search across every type, search inside lyrics, recent searches. Finamp #293 (12).
      https://support.symfonium.app/c/feature-requests/8/l/top?period=all
- [ ] Find missing albums through MusicBrainz and request them through Lidarr. Jellify's top issue (9).
      https://github.com/Jellify-Music/App/issues?q=is%3Aissue+sort%3Areactions-%2B1-desc

### Playback

- [ ] Radio and instant mix from sonic similarity (OpenSubsonic sonicSimilarity, AudioMuse-AI). Navidrome's top
      discussion (47), Jellyfin sonic analysis (98). https://github.com/navidrome/navidrome/discussions?discussions_q=sort%3Atop
- [ ] Better queue: "Play next" and "Add to queue", save the queue as a playlist, keep queue and position across
      restarts, autoplay when the queue ends. Finamp #60 (18), Feishin #640 (17).
      https://github.com/jeffvli/feishin/issues?q=is%3Aissue+sort%3Areactions-%2B1-desc
- [ ] More shuffle modes: random album, whole library, by album, queues of albums or artists. Tempo #289 (13).
      https://github.com/CappielloAntonio/tempo/issues?q=is%3Aissue+sort%3Areactions-%2B1-desc
- [ ] Streaming quality per network: original on Wi-Fi, transcoded on cellular, separate quality for downloads. Finamp
      #44 (19).
- [ ] Audiobooks and long audio: resume per track, chapters, playback speed, Audiobookshelf. Jellyfin's top request of
      all (859). https://features.jellyfin.org/api/v1/posts?view=most-wanted
- [ ] Bit-perfect USB DAC output on Android, and an honest format, bitrate and sample rate readout. Symfonium (23).
      https://lemmy.world/post/21103002
- [ ] CUE sheets and more formats (APE, WavPack, AIFF, DSD). Jellyfin cuesheet (173).
- [ ] Audio focus: pause at volume 0, resume after interruptions. Auxio #637 (8).
- [ ] ReplayGain auto mode and target level. Feishin #374 (15), Retro #270 (12).
- [ ] Word-level synced lyrics and external .lrc files. Navidrome #1421 (56).

### Interface

- [ ] Animated covers (animated WebP), artist images, per-song art. Symfonium's second request of all time (75).
      https://github.com/RetroMusicPlayer/RetroMusicPlayer/issues?q=is%3Aissue+sort%3Areactions-%2B1-desc
- [ ] Customizable home and tabs: recents, most played, random picks, "on this day", tab order, start screen. Jellyfin
      home carousels (82). https://github.com/FoedusProgramme/Gramophone/issues?q=is%3Aissue+sort%3Areactions-%2B1-desc
- [ ] Gestures: swipe the cover to skip, swipe a row to play next or queue. Gramophone #144 (8).
- [ ] Pure black theme and alternate app icons. Amperfy #486 (5).
      https://github.com/BLeeEZ/amperfy/issues?q=is%3Aissue+sort%3Areactions-%2B1-desc
- [ ] Search inside settings. Symfonium (27).

### Integrations

- [ ] Self-hosting connectivity: LAN and WAN addresses with auto-switch, client certificates, self-signed certificates,
      custom headers (Cloudflare Access), SSO and Jellyfin Quick Connect, several libraries. Feishin #986 (30), #715
      (29).
- [ ] Remote control and jukebox: "play on" another device, the Subsonic jukebox API. Navidrome #364 (48).
- [ ] UPnP/DLNA speakers, beyond Chromecast. Feishin #195 (29), Navidrome #305 (28).
- [ ] TV and watch apps: Android TV, Apple TV, Apple Watch and Wear OS with offline. Tempo #413 (12), Finamp #848 (12).
- [ ] Library browsing and instant mix inside CarPlay and Android Auto. Amperfy #503.
- [ ] Sharing: server share links, ListenBrainz and Libre.fm, collaborative playlists, listening together. Navidrome
      #390 (25), #1551 (23).

### Accessibility

- [ ] A to Z fast scroll. Finamp #694 (7), #125 (6).
- [ ] Respect the system font size, CJK glyphs, seek-step buttons, fine speed steps. Jellify #918, Supersonic #57.

### Other

- [ ] Backup and export of playlists, settings and history. Auxio #902 (7).
- [ ] Automation hooks (Shortcuts, Tasker). Tempo #177 (3).

### Complaints about other apps to turn into strengths

- Abandoned apps: Tempo's fourth most-reacted issue asks whether it is still developed. Keep a visible roadmap and
  steady releases.
- Offline-first claims that don't hold up. https://lemmy.world/post/51674520
- Heat and battery: Amperfy's most-reacted issue (#648, 14) is the phone getting hot from background sync and artwork
  downloads. The spectrum designs need a power budget and a low-power fallback, which the rest mode can share.
  https://github.com/BLeeEZ/amperfy/issues/648
- Misleading quality: Plexamp downsamples above 48 kHz and still shows the original rate.
- Broken multi-artist and genre handling.
- Slow with large libraries: Auxio #1046 (9), Tempus #696.
  https://github.com/eddyizm/tempus/issues?q=is%3Aissue+sort%3Areactions-%2B1-desc
- Too many taps to reach albums in Jellyfin music apps.

### From X

Found through a web search of x.com (October 2026); X's own search could not be opened. These are single posts and
support replies, not vote counts, so they weigh less than the issue reactions above.

- [ ] Free. Fair shuffle: play the whole list before repeating a song, and never mix in songs that aren't in it. Spotify users
      have complained for years that shuffle replays the same songs, and Smart Shuffle couldn't be switched off for a
      long time; Apple Music gets the same complaint. https://x.com/atlanticism/status/2103822995164688668
      https://x.com/cantcomputer/status/1737846454939787571 https://x.com/Tyzillatyzilla/status/2084702169157005419
- [ ] Pro, only through official APIs. Import a playlist from a public Spotify or YouTube Music link, matching tracks
      against the user's own library by title and artist. Asked of both
      Apple Music and YouTube Music. https://x.com/iAnkurThakur/status/1937051384953868618
      https://x.com/MesssyLive/status/1996357564196622362
- [ ] Free. Recently played shown above the queue, in the same list. https://x.com/Sankew06/status/2044272779781124210
- [ ] Pro, with on-device translation so it has no running cost. Lyrics translation and pronunciation. Spotify and Apple Music already have it, and lyrics demand is high in Japan.
      https://x.com/tsurezure_lab/status/2019188974032728159
- [ ] Free. Pin up to 20 items at the top of the library. Spotify called it one of its most requested updates.
      https://x.com/Spotify/status/2074839915687203258
- [ ] Later. Needs a recommendation source first (the instant mix above). Steer recommendations with "more of" and "less of" notes, like Spotify's Taste Profile.
      https://x.com/precisionalgo/status/2102926012325478831
- [ ] Pro, with the stats and yearly recap. A monthly recap. https://x.com/SpotifyCares/status/2074519246948720951
- [ ] Subscription or skip. Needs a server, which the rest of the app avoids. Friends' listening activity and listening
      together. https://x.com/TechlusiveOFCL/status/2009123484094636167
- [ ] Pro. Audio effects beyond the equalizer: reverb and compression. https://x.com/hOnozuka/status/2079554728799916274

Complaints to turn into strengths:

- Spotify mobile reportedly dropped the plain queue and regular shuffle that desktop still has. Keep both on every
  screen. https://x.com/even_egger_yolk/status/2072874321702273479
- Slow skips: the next song takes too long to start when skipping quickly through a shuffle. Prefetch the next tracks.
  https://x.com/wholemars/status/1939005888288752068
- No background play on game consoles, so people drive Spotify on the PS5 from the phone. The remote control item above
  covers the phone side. https://x.com/SilenceOfAura/status/2024380985895506278
- A customizable 10-band equalizer is still asked of Apple Music. Cauce already has one, so show it off.
  https://x.com/malcompute/status/2073862233445335341

## Before publishing

- [x] Check the licence of each lyrics source. LRCLIB and lyrics embedded in the files are safe; others may need a
      licence. Kept LRCLIB and embedded and .lrc lyrics; removed Musixmatch, Kugou and NetEase
- [x] Use the Subsonic server's lyrics. `SubsonicLyrics` (structured OpenSubsonic lyrics, with a plain-text
      fallback) is the `server` lyrics group, tried after `.lrc` files and before LRCLIB
- [x] Build the store flavour without the unofficial providers
- [ ] Ask to be listed in Navidrome's catalog of Subsonic/OpenSubsonic clients
      (https://x.com/navidrome/status/2002413209488433306)

## Monetization

1. Free, with a one-time "Pro" unlock for designs, equalizer and themes
2. A low-priced subscription only if something with an ongoing cost is added, such as sync
3. Tips through GitHub Sponsors or Ko-fi

Ads are not recommended: in a music player they annoy and pay little.
