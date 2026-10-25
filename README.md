# Cauce

A music player for iPhone that brings your streaming services and your own music into one
library and one queue. The UI is Flutter; the providers, playback, downloads and the encrypted
offline vault run in Rust, reached through [flutter_rust_bridge](https://github.com/fzyzcjy/flutter_rust_bridge).

## Providers

- Spotify (Premium streams; free accounts play their songs from your other services)
- Tidal
- Deezer
- YouTube Music
- Subsonic servers (Navidrome, Gonic, Airsonic, …)
- The songs in the phone's Music library

Lyrics, Last.fm / ListenBrainz scrobbling and offline downloads are built in.

## Layout

| Path | What it holds |
| --- | --- |
| `lib/` | The Flutter app |
| `rust/cauce_core` | The app's core: session, settings, downloads, lyrics, scrobbling |
| `rust/cauce_bridge` | The API exposed to Dart |
| `rust/vendor/` | Vendored crates (`sonora`: providers and storage; `librespot`) |
| `rust_builder/` | The cargokit plugin that builds the Rust library for each platform |
| `ios/` | The iOS runner, with the native now-playing, media library and browser channels |

## Building

You need Flutter (stable), a Rust toolchain with the iOS targets, Xcode and CocoaPods:

```sh
rustup target add aarch64-apple-ios aarch64-apple-ios-sim
cargo install flutter_rust_bridge_codegen --version 2.13.0
flutter pub get
```

After changing the Rust API in `rust/cauce_bridge/src/api`, regenerate the Dart bindings:

```sh
flutter_rust_bridge_codegen generate
```

Checks:

```sh
dart analyze lib test
flutter test
cd rust && cargo test -p cauce_core -p cauce_bridge --lib
```

## Installing on an iPhone

1. Open `ios/Runner.xcworkspace` in Xcode, select the Runner target and set your team under
   *Signing & Capabilities* (change the bundle id `dev.manuxdev.cauce` if it is taken).
2. Enable Developer Mode on the phone (*Settings → Privacy & Security*) and connect it.
3. Build and install:

   ```sh
   flutter build ios --release
   xcrun devicectl list devices
   xcrun devicectl device install app --device <UDID> build/ios/iphoneos/Runner.app
   ```

4. The first time, trust the developer profile in *Settings → General → VPN & Device Management*.

## License

GPL-3.0-or-later, see [COPYING](COPYING). Cauce is derived from
[Sonora](https://github.com/sonorahq/sonora) (GPL-3.0-or-later).
