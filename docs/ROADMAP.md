# Roadmap & status

Legend: ✅ works and verified · 🟡 partial · ⬜ not started. Updated after every phase.

## Phase 1 plan — foundation & SwiftUI dashboard

1. Convert to SwiftPM: `StudioCore` (Swift 6) + `WallpaperStudio` (app) + `StudioCoreTests` (Swift Testing). `build.sh` assembles and signs `Wallpaper Studio.app`.
2. `AppContainer` (dependency injection) created at launch and passed to views — no singletons in views.
3. Logging (`Log` categories) in the core.
4. Dashboard: sidebar with Discover · My Library · Editor · Playlists · Displays · Settings, dark appearance by default, rounded cards, persistent Now-Playing bar.
5. Make every sidebar page honest: pages backed by working features are real (Discover, Library, Playlists, Displays [read-only], Settings); the Editor states plainly that it arrives in Phase 11.
6. Tests for core logic (catalog integrity, sidebar order). Build, run, verify launch.

## Phases

| # | Phase | Status |
|---|---|---|
| 1 | Foundation + dashboard | 🟡 built, tests pass, launches; UI not yet visually verified |
| 2 | AppKit desktop window management (DesktopWindowManager, per-display sessions, wake/sleep restore) | 🟡 implemented; automated checks pass; hardware scenarios need manual testing |
| 3 | Static + video renderers behind `WallpaperRenderer` | 🟡 implemented; automated tests pass on real media; on-screen look not yet seen |
| 4 | Library + local storage (SQLite, tags, favourites, import) | 🟡 implemented; 51 automated tests pass; UI not yet seen on screen |
| 5 | Multi-monitor management | 🟡 implemented; 83 automated tests incl. synthetic multi-display setups; never run on real multiple monitors |
| 6 | Metal engine | 🟡 implemented and measured; 147 tests; particles/mouse/audio inputs are Phases 7-8; never seen on screen |
| 7 | Mouse interaction + particles | 🟡 implemented and measured; 192 tests; never seen on screen, real cursor/click/typing events untested by automation |
| 8 | Audio-reactive | 🟡 implemented; DSP and GPU verified; real system-audio/microphone capture never run (needs permissions) |
| 9 | Performance engine (profiles, thermal) | 🟡 implemented, measured; real thermal/battery/memory events untested |
| 10 | Web wallpapers + .wsp | 🟡 implemented, hostile-input tested; never seen on screen |
| 11 | Editor | 🟡 implemented, model/export/preview tested; UI never seen on screen |
| 12 | Automation, distribution, community | 🟡 automation + DMG done; notarisation and online/community not done |

## Phase 1 status

Verified: `swift build -c release` succeeds, `swift test` passes (4 tests), the app launches and stays running.
Not verified: how the window looks and every page's behaviour on screen (no screenshot access in the dev session).
Known limits: engine is still the Swift 5 prototype (no `WallpaperEngine`/renderer protocols yet, Phase 2-3);
Displays page is read-only; no integration tests yet; no SwiftData/SQLite store yet (Phase 4).

## Phase 2 status

Implemented
* `DisplayReconciler` (core, pure) decides which per-display windows to add / remove / keep; 7 unit tests.
* `DesktopWindowManager` reuses windows across display changes (no flicker), creates/destroys only for displays that appear/disappear, realigns frames on resolution/arrangement change, re-asserts desktop level, order and video layer after wake and Space changes.
* `SystemEventMonitor` turns sleep / wake / screens-changed / Space-changed notifications into one event stream (wake is handled twice, 1.5 s apart, because displays can finish waking late).
* `DisplayManager` publishes `DisplayDescriptor`s keyed by `CGDirectDisplayID`; the Displays page uses it.

Verified on this machine
* `swift build` and `swift test` (11 tests) pass.
* Launched app: `CGWindowList` shows exactly one wallpaper window per screen, at the desktop window level (-2147483623), 1920x1080, on screen.

Not verified (needs hardware / manual run): second display hot-plug, sleep/wake, Mission Control, Spaces, fullscreen apps, Stage Manager.

Manual checklist
1. Plug/unplug an external display: wallpaper appears/disappears there with no flicker on the other display.
2. Change resolution in System Settings: window follows.
3. Sleep, wake: video resumes within ~2 s, no black frame stuck.
4. Switch Spaces / open Mission Control: wallpaper stays; desktop icons remain clickable.
5. Enter a fullscreen app: playback pauses (log: Settings > "Pause when desktop is covered"); exit: resumes.

Known limits: all displays still share one `AVPlayer` (per-display players come with Phase 5); the legacy engine remains in `main.swift`.

## Phase 3 status

Implemented
* `WallpaperRenderer` protocol: one renderer per wallpaper, one layer per display (shared decoder/image across displays).
* `VideoWallpaperRenderer`: AVFoundation hardware decoding into `AVPlayerLayer`, gapless `AVPlayerLooper` for single videos, end-of-item callback for playlists, speed/volume/mute/fill, snapshot.
* `StaticImageRenderer`: JPG/PNG/HEIC/TIFF/BMP/WebP decoded with ImageIO at no more than the largest display's pixel size (EXIF orientation honoured).
* `AnimatedImageRenderer`: GIF/APNG decoded once (256 MB memory cap, auto-downscaled) and played as a Core Animation keyframe animation; pause/resume/speed; single-frame GIFs fall back to static.
* `RendererFactory`, 0.6 s cross-fade when switching wallpapers, bad files rejected before they replace the current wallpaper, library thumbnails for images.
* Playlists can mix videos and images; images rotate on a timer (30 s if "Switch every" is Off).
* The engine in `main.swift` now talks only to the renderer protocol (no `AVPlayer` there any more).

Verified
* `./test.sh`: 22 tests pass (14 core + 8 renderer tests that generate real PNG/GIF/MP4 files and run them through the actual decoders: kind selection, downsampling, corrupt-file handling, GIF animation/pause/resume/speed, video gravity/snapshot/teardown, end-of-video callback).
* App launches with a GIF as the saved wallpaper, stays running, wallpaper window present at desktop level.

Not verified: how it looks on screen (no screenshot access), GPU/CPU/memory cost (Phase 9 measures this), WebP animation (static only), long-running behaviour.

Testing note: with only the Command Line Tools, plain `swift test` fails to find the Swift Testing macro plugin; use `./test.sh`.

## Phase 4 status

Implemented
* **SQLite store** (`SQLiteLibraryStore`, an actor in `StudioCore`, system SQLite, WAL, foreign keys, schema versioning via `user_version`, refuses databases from a newer schema).
* **Managed storage** at `~/Library/Application Support/LiveWallpaper/Library/` (`library.sqlite`, `files/`, `thumbs/`, `downloads/`). Imports are copied/moved in, never referenced in place.
* **Import pipeline**: type check, real decode check, streaming SHA-256 de-duplication (re-importing something in the trash restores it), copy, metadata probe (size, resolution, duration), JPEG thumbnail. Drag & drop of files and folders (up to 500 files), "Add Wallpaper…" with multi-select.
* **Library UI**: search (case/accent-insensitive across title, tags, category, type), tabs All / Favorites / Recent / Trash, collections, tag chips, sort (newest, oldest, title, most played), type filter, favorite heart, context menu, detail sheet with live video preview, rename, tags, collections, metadata, show in Finder.
* **Trash**: soft delete, restore, delete forever, empty trash, automatic purge after 30 days.
* **Export / Import Library** as one `.zip` (works offline). Import validates entry names before extraction, rejects symlinks, ignores paths stored in the database, and re-imports each file through the normal pipeline; collections merge by name.
* **Discover downloads** now land in the library with catalog metadata (category, tags); old downloads and "added" files from before the database are migrated once.
* The library works fully offline (only Discover thumbnails/downloads need the network).

Verified
* `./test.sh`: 51 tests pass (32 core, 19 app), three consecutive runs. Includes: SQLite round-trip of every field, reopen persistence, duplicate hash, update/not-found, collections + cascade, case-insensitive unique names, path-traversal file names refused, backup, newer-schema refusal, filter/sort/search behaviour, import into managed storage with thumbnail/metadata, de-duplication, corrupt-file rejection with no leftover files, trash/restore/delete-forever file handling, batch folder import with skip report, restart persistence, play counting and missing-file handling, export→import round trip (twice, no duplicates), a hand-built zip with a `../` entry refused before extraction, a non-library zip refused, legacy migration run once.
* App launches and creates the real database (`PRAGMA user_version` = 1 with the expected tables).

Fixed along the way: `VideoWallpaperRenderer.snapshot()` could fail before the first frame/at loop boundaries (now tolerant).

Not verified / limits
* Not seen on screen (no screenshot access): grid layout, drag-and-drop overlay, detail sheet, menus.
* Drag & drop and the NSOpenPanel/NSSavePanel flows are untested by automation.
* No "restore from export of trashed items"; trashed items are not exported.
* Tags are stored as JSON in one column (filtered in memory) — fine for thousands of items, revisit if libraries get huge.
* Export holds the data in a temp folder (hard-linked where possible) before zipping; very large libraries need free disk space for the zip.

## Phase 5 status

Implemented
* **Per-display sessions** (`DisplaySession`): own window, own renderer, own settings and pause state. `DesktopWindowManager` now takes display descriptors (id, UUID, frame) instead of `NSScreen`, so it can be tested with synthetic displays.
* **Three modes** (remembered per *set* of connected displays, so docking/undocking switches automatically):
  * *Same on all*: one shared renderer, a layer in every window (one decoder however many displays).
  * *Different per display*: each display has its own wallpaper (library item or any file), scaling (fill / fit / stretch), rotation (0/90/180/270), speed, volume/mute, frame limit and pause.
  * *Span*: one picture across the whole desktop; each window shows its slice (`SpanLayout`, handles negative origins and stacked layouts).
* **Remembered displays**: settings are keyed by the display's UUID (`CGDisplayCreateUUIDFromDisplayID`), so a reconnected monitor, even with a new `CGDirectDisplayID`, gets its settings back. Unplugged displays are listed with a Forget button. State lives in `~/Library/Application Support/LiveWallpaper/displays.json` (atomic writes; a damaged or newer-version file is kept as `.corrupt` and defaults are used).
* **Reconnection / resolution change**: windows are reused and re-sized, content survives; a missing per-display file falls back to the main wallpaper.
* **Per-display playback**: pause one display without touching the others; "pause when covered" works per window in independent mode.
* **Frame limit** for animated GIFs: frames are resampled on a fixed time grid (`FrameRateLimiter`), total duration preserved, applied live.
* **Identify** button flashes the display's number on that screen.
* Playlist advance is driven by exactly one renderer in every mode (tested).

Bug found by tests and fixed: clearing the main wallpaper left the old picture on screen in mirror/span mode.

Verified
* `./test.sh`: 83 tests pass (47 core + 36 app), three consecutive runs. New: display-layout state/persistence/corruption handling, span/rotation geometry, frame limiter, and manager tests with two synthetic displays (hot-plug, mirror sharing, span slices, independent wallpapers + rotation + scaling, per-display pause, fallback, mode switching, reconnect with new id, resolution change, single "finished" binding, no rebuild when unchanged), layout-controller persistence.
* Real launch on this Mac: the LG ULTRAGEAR is detected by UUID, `displays.json` is written, the desktop-level window is on screen.

Not verified / limits
* **Never run with two real displays** (only one is connected here): hot-plug, arrangement changes, mixed refresh rates and mixed scale factors are covered by synthetic tests only. Use the Phase 2 checklist plus: switch modes with two monitors, rotate a portrait monitor, unplug/replug.
* **Video frame-rate cap is not implemented** (AVPlayerLayer cannot be throttled without a fragile video-composition path). The control is disabled for videos with an explanation; real control comes with the Metal pipeline (Phase 6).
* Rotation is ignored in Span mode (documented behaviour).
* Mirror mode uses one global scaling/speed/volume (the main-wallpaper settings); per-display values only apply in Different-per-display mode.
* In independent mode each display with its own video decodes it separately; GPU/CPU cost is not yet measured (Phase 9).
* The Displays page layout has not been seen on screen.

## Phase 6 status

Implemented
* **Scene model** (`StudioCore`, pure data, no GPU types): layers (solid, gradient, image, video, procedural), blend modes (normal/add/multiply/screen), transforms, effects, keyframe **tracks** (linear/ease/step, once/loop/ping-pong), parallax depth, `SceneEvaluator` (tracks + pointer input → resolved layers), `LayerGeometry` (fill/fit/stretch, rotation, aspect-correct), `SceneCodec` (`.wsscene` JSON, size/layer/number/asset-name validation), `EffectPreset`s, `BuiltInScenes`, `RenderQuality` (resolution + fps rules).
* **`StudioRender` target** (Metal): `MetalContext` (device, queue, shaders compiled from source at launch, 4 blend pipelines), uber-shader (textures, solid/gradient, plasma/aurora/waves procedurals, hue shift/cycle, brightness/contrast/saturation, vignette, ripple distortion, animated light with flicker, depth-map parallax), `SceneRenderer` (per-frame work is one render pass; uniforms via `setBytes`, no per-frame buffers), `ImageTexture`, `VideoTexture` (AVFoundation hardware decode → `CVMetalTextureCache`, zero-copy), `OffscreenRenderer` (thumbnails, snapshots, tests), measured `RenderStats` (GPU/encode time).
* **App integration**: `MetalSceneRenderer` behind the same `WallpaperRenderer` protocol: a `CAMetalLayer` per display, one decoder/texture set shared by all displays, `CADisplayLink` pacing with a time-budget limiter (display links only offer rates that divide the refresh rate, e.g. 10 fps on a 144 Hz screen ticks at 12 Hz, so the cap is enforced in software), static scenes draw on demand only, adjustable **render resolution** (100/75/50/25 %), pause/resume, video end callback for playlists.
* **Routing**: plain images/videos/GIFs stay on Core Animation (cheapest). The GPU path is used for `.wsscene` files, images/videos with an effect, and **videos with a frame limit** (this finally implements the video frame cap that Phase 5 could not).
* **UI**: "Generated on your GPU" wallpapers in Discover (Plasma, Aurora, Night Waves; installed into the library as `.wsscene`, thumbnails rendered by the GPU), Settings → Visual (effect, resolution, frame limit, live GPU timing), per-display effect/resolution/frame-limit controls. Library, search and export/import handle scenes.

Verified (147 tests pass, three consecutive runs)
* Real GPU pixel tests: solid/opacity/gradient orientation, all four blend formulas, keyframed opacity at three times, position/scale, image orientation (top-left origin), clockwise rotation, fit letter-boxing and fill cropping, missing assets skipped, hue shift/cycle, saturation, brightness/contrast, vignette overlay, moving light following its timeline, ripple displacement, procedural scenes deterministic + animating, every built-in scene non-black, pointer parallax moves near layers and not far ones, depth maps decide how far pixels move, a real H.264 video frame arrives as a texture.
* Shader/Swift uniform layout is asserted (176-byte stride, field offsets).
* **Frame cap measured**: 10 fps cap → 19-21 frames in 2 s; 30 fps cap → 57-58 frames in 2 s (display is 144 Hz). Pausing stops frames; resuming continues. Static scenes draw a handful of times, not continuously.
* **GPU cost measured** (1080p, Night Waves, 60 frames, M-series): average 0.5-0.6 ms GPU, max 1.1-1.6 ms, encode 0.02-0.04 ms per frame.
* **Real app, GPU scene (Plasma) on the LG ULTRAGEAR (144 Hz)**: uncapped ≈ 7-9 % CPU; with a 30 fps limit ≈ 1.5 % CPU; resident memory ≈ 120 MB in both. (CPU from `ps`/`top` over ~8 s; a rough number, not a profile.)
* Old `displays.json` files without the new fields still load.

Bugs found and fixed by the tests: `MTKTextureLoader` returned channel-swapped data for ImageIO images (textures are now redrawn into a known BGRA layout before upload); hue shift rotated the wrong way round (YIQ vs HSV); the Aurora scene's vignette layer was opaque black and hid everything.

Not done / limits
* **No particle systems, mouse reactivity or audio reactivity yet** (Phases 7-8). `SceneInput` and `MetalSceneRenderer.setPointer` are in place for them; parallax works if the pointer is fed.
* No depth-map *generation* (needs Vision/Core ML, later); no blur/bloom (multi-pass); no GIF layers inside Metal scenes (GIFs stay on Core Animation); video `preferredTransform` (rotated phone clips) is ignored in the Metal path.
* Colours are blended in sRGB-encoded space (matches the Core Animation path; not physically linear).
* Scenes that reference external media cannot be imported yet (they need the `.wsp` package format, Phase 10).
* Mirror mode draws the scene once per display (one decoder, N draws).
* Never seen on screen (no screenshot access); GPU timing is on the dev machine only; not profiled with Instruments (no Xcode).

## Phase 7 status

Implemented
* **GPU particle systems** as a scene layer type: a compute kernel simulates up to 50 000 particles per layer in a buffer allocated once (emitter shapes: point, box, *pointer*; lifetime, speed, direction/spread, gravity, drag, turbulence, size/colour over life, additive/normal/screen blending), drawn as instanced soft sprites. Deterministic: an integer hash (PCG) shared by CPU and GPU.
* **`ParticleReference`**: the same physics on the CPU (readable spec, test oracle). The GPU is verified against it.
* **Mouse-reactive behaviour**: particles can be attracted, repelled or swirled around the cursor; the pointer can be an emitter (trails); **clicks launch bursts** from the click position; typing can make particles swell. Declarative **input bindings** (`pointerX/Y`, `pointerSpeed`, `clickPulse`, `keyPulse` → any animatable property) make any layer react; parallax now uses a documented convention (y up). Built-in scenes: **Fireflies**, **Snowfall**, **Stardust Trail**, **Cursor Light** (appear in Discover → Generated).
* **`InteractionHub`** (app): one shared set of `NSEvent` monitors. Mouse moves/clicks are observed with global + local monitors (no permission; clicks still reach Finder). Monitors run **only while a wallpaper that needs them is playing**. A static scene redraws only when input arrives.
* **Per-display mapping**: the cursor is mapped onto each layer's display (the whole desktop in Span mode), with the display rotation undone; the particle simulation runs once per frame, driven by the display the cursor is on.
* **Typing reactions are opt-in and privacy-preserving**: off by default; requires macOS Input Monitoring permission (requested only when the user turns the switch on); the key event's contents are never read, only a decaying "how much typing" level exists. Settings → Interaction has both switches and explains this.

Verified (192 tests pass, three consecutive full runs)
* **GPU = CPU reference**: initial state of 512 particles within 1e-3; after 120 steps with gravity, drag, turbulence and an attracting pointer, 600 particles agree within 0.02 and every respawn generation matches exactly.
* Bursts launch exactly the requested window of particles (wrapping the buffer end) from the click position; a high click counter at startup causes no burst.
* CPU physics tests: gravity/drag/attract/repel/swirl, respawn, staggered vs pre-warmed start, pointer ignored when inactive, pointer emitter follows and parks, deterministic seeds.
* Rendering: soft round sprites, invisible before emission, typing swells sprites ≥3×, layer opacity, bindings move a cursor light left/right.
* Interaction: hub reference counting and permission rules, keyboard needs setting **and** permission, monitors stop when the wallpaper pauses, static scenes redraw only on input, pointer mapped to the right display and rotation, click and speed signals arrive in the simulation, scenes that ignore input start no monitors.
* **Measured**: 20 000 particles with pointer repulsion and turbulence at 1080p: **0.22–0.28 ms GPU/frame** (compute + draw), encode 0.01 ms. Real app on the LG (144 Hz), pause-when-covered off so it really renders: Fireflies 11.6 % CPU uncapped → 2.6 % at a 30 fps cap; Snowfall 9.8 % → 2.3 %; Cursor Light 7.7 % → 2.1 %; memory 85-95 MB. (`top`, ~10 s; rough, not a profile.) With pause-when-covered **on** and the desktop hidden behind windows the same scene used ~0 % CPU, which shows the covered-pause works.

Not done / limits
* **Not seen on screen**; real cursor movement, desktop clicks and typing were not exercised by automation (the logic is tested with injected sources, the `NSEvent` monitors themselves are thin glue).
* **No interaction zones** (regions that trigger actions): that belongs to the editor (Phase 11). `KeyboardInteractionController`/`ParticleInteractionController` exist as the hub's key source and the particle pointer modes rather than separate classes.
* **Multi-display particles**: one simulation is shared by all displays, driven by the display with the cursor; other displays show the same particles.
* The particle simulation is a stable semi-implicit Euler integrator, not collision-aware; no particle textures/sprite sheets or trails with history.
* Audio-driven reactions are Phase 8 (`InputSource` is ready for audio bands).

## Phase 8 status

Implemented
* **Analysis** (`StudioCore`, Accelerate): Hann window → 2048-point FFT every 1024 samples → 32 log-spaced bands (40 Hz-16 kHz) → dB mapping with a +3 dB/octave tilt and a user **sensitivity** gain (+6 dB per doubling) → attack/release **smoothing** (user-adjustable) → bass / mid / treble (RMS of their bands), overall level, 64-point waveform, and a **beat detector** (sudden bass rise over a running average, minimum gap, serial counter). Works at any sample rate.
* **Capture** (app): `SystemAudioCapture` (ScreenCaptureKit audio stream; 2×2 px, 1 fps video that is discarded; our own app's sound excluded) and `MicrophoneCapture` (AVAudioEngine tap), both converting to mono through tested helpers (planar and interleaved Core Media buffers).
* **Consent model** (`AudioReactiveEngine`, enforced by tests): audio is **off by default**; nothing is created or started in `.off`; `start()` never shows a system prompt, it only reports "needs permission"; the permission prompt can only come from the user choosing a source in Settings → Audio; capture runs **only while an audio-reactive wallpaper is playing** (reference-counted through `InteractionHub`) and stops when it pauses; stale frames fall back to silence after 0.4 s; late callbacks from a stopped capture are ignored; failures and revoked permissions show a message and nothing crashes. Audio is analysed live and never recorded or stored. `NSMicrophoneUsageDescription` added to the app.
* **GPU side**: `VisualizerSpec` layers (spectrum bars, mirrored bars, circular ring with rotation, waveform line; per-style gap, glow, thickness, colours low→high, **music-reactive hue drift**), audio data uploaded as one 416-byte buffer per draw (no per-frame allocation beyond the analyser's frame), new binding sources (`audioLevel/Bass/Mid/Treble/Beat`) so any layer/light/colour/ripple can react, bass-reactive particle size, **beat-triggered particle bursts**.
* **Scenes** (Discover → Generated): Spectrum, Pulse Ring (ring + beat sparks + bass light), Waveform Glow, Bass Bloom (plasma hue/brightness follow level/bass). They show a quiet baseline in silence.
* **Settings → Audio**: source picker, sensitivity, smoothing, live 32-band meter, status text, shortcut to the right Privacy pane, plain-language explanation.

Verified (242 tests, three consecutive full runs)
* DSP: tones land in the right band (100 Hz-10 kHz), bass/mid/treble separate, +6 dB per amplitude doubling within ±0.04 of the expected level step, sensitivity acts as gain, release is slower with more smoothing and decays to silence, kick drums at 2 Hz give 8-12 beats in 5 s while a steady tone gives ≤1, waveform follows the signal, other sample rates (44.1/96 kHz), clipped input stays in range, frame cadence (≈46 frames/s).
* GPU: bars rise in proportion to their band and use the low→high colours, mirrored bars grow both ways from the centre, the ring grows where its band is loud, the waveform line sits at the right height, glow adds a halo, hue reactivity shifts colour with loudness (and not without it), silence is a quiet baseline for every style, audio bindings drive lights, bass swells particles, each beat launches exactly the requested burst from the emitter, no burst when the counter starts high; shader/Swift uniform layout asserted (192-byte stride).
* Engine/consent: every rule listed above, plus: granted → tones become frames; retry after a failed start; sample-rate change and live tuning change; hub reference counting; a granted permission restarts a waiting feed; scenes without audio never touch the feed; the renderer receives the frames and releases capture on pause.
* **Measured**: two visualisers at 1080p ≈ 0.35-0.46 ms GPU/frame. Real app (LG, 144 Hz), audio set to System with no permission granted (so silent visuals): Spectrum 5.5 % CPU uncapped → 3.0 % at 30 fps; Pulse Ring 12.5 % → 3.5 %; ~83-95 MB.

Not done / not verified
* **Real capture was never run**: this app has no Screen & System Audio Recording or Microphone permission here, and permission prompts cannot be accepted from the dev session. Everything between the capture callback and the pixels is tested with injected audio; the ScreenCaptureKit/AVAudioEngine glue itself is untested. After granting Screen Recording macOS usually needs an app restart before capture works.
* The ad-hoc signature means macOS may forget the permission after every rebuild (see Architecture, toolchain facts).
* Not seen on screen. Band/level mapping constants (−72…−10 dB, +3 dB/octave tilt) are reasonable defaults, not tuned on a range of real music.
* `AudioFrame` carries bands/waveform/beat only; no stereo separation, no per-application capture, no BPM/tempo.

## Phases 9-12 (built in one stretch)

Test totals after this stretch: **360 tests** (177 core, 53 render, 130 app), three consecutive full runs green.
`./test.sh` runs everything; `./release.sh` runs the tests, builds, packages a DMG.

### Phase 9: performance engine
Implemented
* `PerformancePolicy` (core, pure): four profiles (Battery Saver 15 fps/75 %, Balanced 30, Performance 60 / 30 on battery, Adaptive) combined with conditions: battery (<20 % → 15 fps), Low Power Mode, heat (fair: resolution ×0.85; serious: ≤15 fps ×0.6; critical: pause), memory pressure (warning: trim; critical: trim and ×0.5), number of GPU wallpapers (≥3 → 30 fps), display refresh.
* `AdaptiveGovernor`: steps (60/40/30/24/15 fps with falling resolution) down after 6 s of sustained load or heat, back up only after 25 s calm and a 120 s hold after any pressure step (no oscillation), never above 30 fps on battery.
* App: `PowerMonitor` (IOKit notifications, no polling), `ThermalMonitor`, `MemoryPressureMonitor` (kernel dispatch source), `CPUMonitor` (rusage), `PerformanceController` (publishes limits, only announces real changes), applied live to renderers without rebuilding them; `DesktopWindowManager.trimMemory()` releases the renderers of hidden wallpapers and rebuilds them when visible again; library thumbnail cache is dropped. Settings → Performance shows the live state and the limits in force. **Default profile: Balanced.**
* **Measured (decision-changing):** a 1080p30 video costs ≈1.1 % CPU / 55 MB on the media engine path (`AVPlayerLayer`), but 3.9-16.9 % CPU / 95-109 MB when re-drawn through Metal at a frame cap. So **profiles never force plain videos onto the GPU path** (`performanceFPSCap` is separate from the user's explicit `maxFPS`); caps apply to GPU scenes, effects and GIFs. The UI says so.
* Controller evaluation costs ≈0.8 µs per call.
Verified: policy rules, governor timelines, controller behaviour with injected system state, cap reaching a running GPU renderer without a rebuild (≈10 fps measured with a 10 fps policy), memory trimming and rebuild, GIF caps following the stricter of user/policy.
Not verified: real battery/thermal/memory-pressure events on hardware (only injected), power draw (needs a power meter / Instruments).

### Phase 10: `.wsp` packages and web wallpapers
Implemented
* Format: zip with `manifest.json` (`wsp`, format version 1, id, name, author, version, type scene/video/image/web, entry, preview, permissions pointer/audio, scripts (web only), config, minAppVersion). Custom shaders are rejected for now; scenes finally can carry their own media.
* **Validation before extraction** (core, pure): safe relative paths (no absolute, `..`, hidden, backslashes, control characters, depth ≤ 6), no symlinks, file-type whitelist, ≤ 2000 files, ≤ 256 MB per file, ≤ 512 MB total, duplicate names (case-insensitive), entry/preview/script rules per type, version and minimum-app checks, scene assets present and plain names.
* **Safe extraction** (app): listing parsed from `unzip -Z -l` and validated first; extraction into a fresh temp folder with `unzip` (Finder junk excluded); then the tree is re-scanned (symlinks, undeclared files, real sizes) and every medium is decoded; only then moved into place. Failure leaves nothing behind. Packages install through the normal library import (hash dedup, trash, export/import), are unpacked once and re-unpacked if the cache is deleted.
* **Web wallpapers**: `WKWebView` per display with an ephemeral data store, read access limited to the package folder, all navigation/new windows/frames outside it cancelled, **http(s)/ws(s) blocked by a content rule list**, no audio autoplay, `window.studio` API (`onFrame`, `config`, pause events). Pointer and audio frames are delivered **only if the manifest asks for them and the user has enabled that input**; the inputs are switched on only while the page plays.
* **Scripts**: only inside web wallpapers (WebKit's OS sandbox). No native code from a package is ever loaded or executed; scene packages cannot carry scripts.
Verified: 14 validator tests, hostile archives (path traversal, absolute, nested, hidden, symlink, executable, dylib, forged zip-bomb header) all refused before anything is written and nothing created outside; corrupt content, bad manifests, wrong versions, missing assets; Finder junk; build→install round trip for scene/video/image/web; library import/delete/restore/export; and a **real network test**: a page that tries fetch, XHR, `<img>`, WebSocket and iframes to a local listener opened **0 connections**, iframes to other files/sites were cancelled, `studio` frames arrive only with permission and enabled inputs.
Limits: rotation/span placement do not apply to web wallpapers; a hostile zip that lies in its *local* headers could still write a lot before the post-check (extraction is to a temp folder and checked after); web content cannot `fetch` its own package files (WebKit file-origin rules; use `<script src>`/`<img>` or `studio.config`); custom shaders unsupported; not verified visually.

### Phase 11: editor
Implemented
* `EditorDocument` (core, pure): layers (add/remove/duplicate/reorder, unique ids), every animatable property, **keyframes** (add/replace/move/retime/ease/loop/delete, kept inside the timeline, empty tracks dropped), timeline length, **input reactions** (mouse, typing, audio sources → any property), **mouse zones** (new scene feature: hover/click rectangles that nudge a layer property; saved in scenes), particle presets, `EditorHistory` undo/redo (bounded, drags coalesce into one step), `SyntheticAudio` for previewing audio-reactive layers.
* App: `EditorProject` (project folder with `scene.json`, autosave, reopen, list), asset import (safe unique names; GIF/unsupported/corrupt refused with clear messages), **live Metal preview** (mouse over it is the pointer, click bursts, synthetic audio, `SceneRenderer.update` hot-swaps edits without reloading textures/decoders), **timeline** (ruler, scrubbing, draggable keyframes, easing, loop modes, play/pause), **inspector** for every layer kind (solid, gradient, pattern, image/video + depth map, particles, visualiser), effects, reactions, scene settings and zones; layer list with drag-reorder; templates from all built-in scenes; **export to `.wsp`** (only referenced assets, rendered preview, self-checked), *Add to Library* and *Set as Wallpaper*.
* The editor never talks to the playback engine: it edits `Scene` values and hands over packages.
Verified: 26 core editor tests (every operation, bounds, history, zones, synthetic audio), GPU hot-swap tests (edits keep resources; content changes reload only what changed; the updated scene is what is drawn), project persistence/undo/selection/animated-value semantics, asset import rules, export contents/validity/library round trip/render/thumbnail, invalid export refused, the preview draws live and follows edits, the whole editor window lays out with every layer kind selected.
Not verified: appearance and usability of the editor UI on screen (no screenshots), drag interactions by a real mouse, large projects.

### Phase 12: automation, distribution, community
Implemented
* **Schedule** (core + app): time-of-day rules (ranges, overnight, weekdays, enabled flag; overlap → most recently started wins; DST-correct boundaries), persisted; `SchedulerService` applies the right wallpaper at start-up and at each boundary (and after wake or clock/time-zone changes), and only then, so a manual choice sticks. UI on the Playlists page. **Playlists from collections** ("Play a Collection").
* **Automation links**: `wallpaperstudio://next | pause | resume | toggle | set?title= | mode?value= | profile?value= | open?section=` (Shortcuts "Open URL", Terminal, scripts). Strictly validated; no paths, no deletion/export; unknown links ignored; `set` only plays existing, non-trashed library items by title.
* **File association**: `.wsp`/`.wsscene` (and media as alternates) open in the app → imported and played.
* **Distribution**: app icon (generated by `Tools/make-icon.swift`), versioning (`VERSION`, build number), full Info.plist (URL scheme, document/UTI types, category), `Resources/Entitlements.plist` (hardened runtime, microphone only), `build.sh` (ad-hoc, or Developer ID via `SIGN_IDENTITY`), `release.sh` (tests → build → DMG → optional notarisation/stapling → checksum). `CloudService` seam with an offline implementation: **no network features exist**.
Verified: 14 schedule/link/cloud tests (overnight and Sunday wrap, DST, overlaps, next-change, persistence/corruption, link parsing/round trip), scheduler behaviour with a fake clock, router with a fake target; `release.sh` produced `dist/Wallpaper-Studio-0.9.0.dmg` (3.2 MB) whose app inside verifies (`codesign --verify --deep --strict`) with the right version/icon/URL/UTI keys; **real-app check**: opening a `.wsp` imported and played it, `wallpaperstudio://set?title=…` re-applied it, an unknown title changed nothing (the test package was then removed from the library).
Not done / not verified: **notarisation was not run** (needs an Apple Developer ID and credentials; the script path is untested), no Developer ID signature was applied, Gatekeeper behaviour on another Mac is untested; community features (accounts, sharing, ratings, cloud sync, widgets) are deliberately not built; AppleScript/App Intents are not provided (the link scheme covers Shortcuts); `NSEvent`/IOKit/ScreenCaptureKit glue still untested against real hardware events.

### Environment note
While this stretch ran, the Mac's display was asleep or locked, so `CADisplayLink` delivered no ticks (a bare 20-line test program got 0). Tests therefore use timer pacing; the display-link path is only exercised by the earlier real-app measurements (Phases 6-9) taken while the display was awake.

## Review, fixes and additions (after phase 12)

Found by review/tests and fixed
* **Sidebar did nothing (reported).** The sidebar `List` selected `SidebarSection` while its rows were tagged `Optional(section)`; those are different types, so every click selected nothing and the page became `nil`. Reproduced with a test that selects each row in the real `NSTableView` (all six clicks left the page `nil`), fixed by tagging rows with the selection's own type, and the same test now passes. `RootView` takes an injectable `NavState` so this stays testable.
* **Deadlock introduced by my own "polish".** `MediaInspector.isPlayable` had been changed to wait on an async `load(.isPlayable)` with a semaphore. Called from a Swift-concurrency worker thread (library imports, tests) it parked all workers so the loader could never run, and the whole test run hung. Found by sampling the stuck process; reverted to the synchronous check with a comment explaining why.
* Process helper (`ProcessRunner`) now drains stdout and stderr at the same time (a tool that fills one pipe can no longer block); scene entries and library archives are size/symlink/disk-space checked from the archive listing *before* anything is read or extracted; idle wake-ups removed (only the Adaptive profile polls; the others are event-driven); the editor saves on quit; icon-only buttons have accessibility labels.

Added
* **Lock screen**: macOS lets only the system play video there, so the app can only change what the lock screen *shows*: its picture is the desktop picture. Settings → Lock screen (opt-in) keeps that picture equal to a sharp still (main-display size, up to 4K, JPEG) of the current wallpaper, refreshed a moment after every wallpaper change and the instant the screen locks (`com.apple.screenIsLocked`). It remembers the previous pictures and restores them when switched off, never mistakes its own still for an original, prunes old files, and reports failures. It is a still, not motion.
* **MotionBGs**: Discover → "MotionBGs (browse the web)" is a locked-down in-app browser for motionbgs.com (categories menu, back/forward, open in browser). The site has no open licence for bundling its files (its pages say they are fan-made and "unauthorized duplication" of its site is prohibited), so nothing is scraped or built in: you browse as normal, press **HD** or **4K** on a wallpaper page, and that one download is captured and added to My Library (title from the page address, category MotionBGs, tags motionbgs + resolution). Only the site itself is shown (other links open in your browser; plain http, `file:`, `javascript:` and pop-ups are refused), no cookies/history are kept, only video files up to 1.5 GB are accepted, and a download that is not a real playable video never enters the library.

Verified: sidebar (fails before, passes after), lock-screen service (13 behaviours with a fake desktop), browser policy table (look-alike hosts, schemes), and an end-to-end browser test against a local web server: pressing Download imports a real video with title/tags/thumbnail and leaves no temp file; a `.exe` attachment, a 2 GB declaration and a `file:` link are all refused. An opt-in live test (`WS_LIVE_TESTS=1`) loads one real motionbgs.com page and checks the HD/4K links appear.
Not verified: the lock screen on a real lock (needs the screen to be locked by hand), the browser's look, and motionbgs.com's page layout may change.

### Test-suite hang (fixed)
`ProcessRunner` drained stderr on a Dispatch global queue and then waited for it. Dispatch's workers are shared with Swift concurrency, so
when every caller was parked in that wait the queued reader never got a thread and the whole suite stalled. The reader is now a dedicated
`Thread`. Full suite: 392 tests (162 + 53 + 177), all passing.
