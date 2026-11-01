# Wallpaper Studio

A native macOS live-wallpaper app (Swift, SwiftUI, AppKit, Metal, AVFoundation, WebKit): videos, images, GIFs, GPU-generated scenes,
music- and mouse-reactive wallpapers, web wallpapers, a layered editor, per-display control and a schedule.

## Build, test, package
```bash
./build.sh        # builds "Wallpaper Studio.app" (ad-hoc signed)
./test.sh         # 360 tests (Swift Testing; needs the Command Line Tools only)
./release.sh      # tests, build, dist/Wallpaper-Studio-<version>.dmg (Developer ID + notarisation via env vars, see the script)
```
Requires macOS 14+, Apple Silicon recommended. No Xcode is needed (SwiftPM + Command Line Tools).

## What it does
* **Discover / Library**: 34 free clips, 11 generated GPU wallpapers, drag-and-drop import, search, tags, collections, trash, export/import.
* **Displays**: same on all, different per display (scaling, rotation, effect, frame limit, pause), or span; settings remembered per monitor.
* **Interaction**: mouse parallax, particles, click bursts, optional typing and audio (system or microphone) reactions.
* **Editor**: layers, keyframes, effects, particles, audio visualisers, reactions, mouse zones, live preview, export to `.wsp`.
* **Packages (`.wsp`)**: scenes with media, videos, images and sandboxed web wallpapers.
* **Performance**: Battery Saver / Balanced / Performance / Adaptive; reacts to battery, heat and memory.
* **Automation**: schedule by time of day, `wallpaperstudio://` links, opening files.

## Privacy
Everything is local. Nothing is sent anywhere (the only network use is the optional Discover download and thumbnails).
The microphone and system audio are off until you choose them in Settings → Audio, are only captured while an audio-reactive
wallpaper plays, and are analysed live, never recorded. Typing reactions are off by default and only count key presses.
Web wallpapers cannot reach the network.

## Automation links
`wallpaperstudio://next`, `pause`, `resume`, `toggle`, `set?title=Night%20Waves`, `mode?value=span`, `profile?value=battery`, `open?section=editor`.

## Documents
`docs/ARCHITECTURE.md` (design and macOS limitations) and `docs/ROADMAP.md` (what each phase built, how it was verified, and what is not done).
