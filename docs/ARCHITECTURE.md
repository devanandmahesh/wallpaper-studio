# Wallpaper Studio — Architecture

Native macOS (Apple Silicon) live-wallpaper engine. Swift 6, SwiftUI + AppKit, Metal, AVFoundation. No Electron, no private APIs.

## 1. Current state (before this document)

A working single-target prototype: video playback on desktop-level windows, menu-bar controls, playlists,
a 34-clip Mixkit catalog with downloads, and a basic library window. ~830 lines, Swift 5 mode, compiled with `swiftc`.
It is kept working while the architecture below is introduced phase by phase; nothing is replaced with stubs.

## 2. Toolchain facts that shape the design (verified on this machine)

| Fact | Consequence |
|---|---|
| Only Command Line Tools are installed — no Xcode, no `xcodebuild` | Build with SwiftPM + `build.sh` that assembles the `.app` and ad-hoc signs it. |
| `SwiftUIMacros` plugin is absent | `@State`/`@Binding` macros fail to compile. Use `ObservableObject`/`@StateObject`/`@ObservedObject` (non-macro). Revisit if Xcode is installed. |
| SwiftData macros (`@Model`) not usable without Xcode plugins | Persistence uses SQLite (via the system `sqlite3` C API) or Codable JSON. SwiftData stays a later option. |
| No XCTest, but `Testing.framework` (Swift Testing) ships with CLT | Unit tests use `import Testing`, run with `swift test`. |
| No `metal` offline compiler (needs Xcode) | Metal shaders ship as source strings and are compiled at launch with `MTLDevice.makeLibrary(source:options:)`. Cache pipeline states. |
| Ad-hoc code signature | Screen-recording / microphone TCC grants may reset when the binary changes. Stable Developer ID signing is required for distribution (Phase 12). |

## 3. macOS API limitations (design constraints)

* **No public API renders into the real wallpaper layer.** We draw borderless windows at `CGWindowLevelForKey(.desktopWindow)`; Finder icons sit above (`desktopIconWindow`), so icons stay clickable. Windows use `ignoresMouseEvents`.
* **Lock screen / login window cannot show live content.** Fallback: "Use current frame as static wallpaper" (implemented) and automatic static-frame sync (planned).
* **Spaces / Mission Control / fullscreen apps**: windows use `.canJoinAllSpaces + .stationary`. A fullscreen app hides desktop windows; we detect via `NSWindow.occlusionState` and pause (implemented). Behaviour must be verified manually per macOS release.
* **Mouse interaction**: desktop windows cannot receive events without blocking Finder. Interaction uses global `NSEvent` monitors (needs Accessibility/Input Monitoring consent for global mouse *and* keyboard, mouse position alone via `NSEvent.mouseLocation` needs none).
* **System audio** only via ScreenCaptureKit (`SCStream`, audio-only config) → requires Screen Recording permission. Microphone via `AVAudioEngine` → microphone permission. Neither starts without an explicit user action.
* **WebKit wallpapers** are `WKWebView` in the desktop window (cannot be composited inside Metal directly); sandbox: no file access outside the package, `WKContentWorld` isolation, no native bridge beyond audio-spectrum / mouse messages.
* **Packages (.wsp)** are zip archives. Foundation has no zip API: validate the entry list first (`/usr/bin/unzip -Z1`), reject absolute paths, `..`, symlinks, oversize/over-count entries, then extract with `/usr/bin/ditto -x -k` into a fresh temp dir. Scripts run only in `JavaScriptCore` with no native objects exposed.
* **Video**: AVFoundation decodes on the media engine (hardware). Metal composition reads frames via `AVPlayerItemVideoOutput` + `CVMetalTextureCache` (zero-copy `IOSurface`). Plain video wallpapers should stay on `AVPlayerLayer` (cheapest) and only go through Metal when effects are applied.

## 4. Module boundaries (SwiftPM targets)

```
StudioCore            pure Swift, no AppKit UI. Models, protocols, policies, catalog, logging. Swift 6 mode. Unit-tested.
WallpaperStudio       app target: AppKit desktop windows, SwiftUI views, platform monitors, services' implementations.
StudioRender          Metal engine (scene renderer, textures, video textures, offscreen). No UI. Swift 5 mode (Metal types are not Sendable).
(app)    Engine/Renderers  Core Animation renderers + `MetalSceneRenderer` behind the `WallpaperRenderer` protocol.
(later)  StudioPackage  .wsp validation/extraction, no UI.
```

Dependency rule: UI → services (protocols) → core. Renderers and platform monitors never import SwiftUI views.

### Component map (from the brief) → home

| Layer | Components | Target |
|---|---|---|
| Application | AppContainer (DI), Dashboard, Discover, Library, Settings, menu bar | WallpaperStudio |
| Engine | WallpaperEngine, DesktopWindowManager, DisplayManager, WallpaperSessionManager, PlaybackController, PerformanceController | WallpaperStudio → StudioRender |
| Rendering | `WallpaperRenderer` protocol; Static/Video/AnimatedImage/Metal/Web/Scene/Particle/Shader renderers; `RendererFactory` | StudioRender |
| Interaction | CursorTracker, Mouse/Keyboard/Particle interaction, AudioReactiveEngine | WallpaperStudio |
| Platform | PowerMonitor, ThermalMonitor, PermissionManager, SpaceManager, SystemEventMonitor, DisplayEventMonitor | WallpaperStudio (protocols in StudioCore) |
| Services | LibraryService, ImportService, CacheService, PlaylistService, SchedulerService, PackageService, CloudService | protocols in StudioCore, impls in app |

Cross-cutting: `os.Logger` categories (`Log.engine`, `Log.library`, …); errors are typed enums, never swallowed silently; no force unwraps.

## 5. Concurrency model

UI, AppKit windows, and players are `@MainActor`. Heavy work (thumbnailing, hashing, FFT, package extraction, downloads) runs in actors/detached tasks and returns `Sendable` values. `StudioCore` compiles in Swift 6 language mode; the legacy engine file stays in Swift 5 mode until it is rewritten in Phases 2–3.

## 6. Extensibility (not built yet)

Protocols + a `WallpaperKind` enum leave room for AI generation, depth maps, accounts, cloud sync, sharing, ratings and widgets. `CloudService` is a protocol only; nothing network-facing beyond the Mixkit download exists until the core is stable.
