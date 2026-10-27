# Port to original

Features built on `dev` that should later go to the `original` branch as well. Port them only when asked, and keep
what makes `original` special: its providers, their sign-in flows and their provider features.

Store-only commits (removing providers or lyrics sources, the bundle id, store copy) never go to `original`.

| Commit | Feature | Notes |
|---|---|---|
| `f6e7732` | Play next, add to queue, queue saved at once, scrolling track options sheet | Touches the bridge, so regenerate it with `flutter_rust_bridge_codegen generate` after porting. The track options sheet in `original` also has its provider rows |
