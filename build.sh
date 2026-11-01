#!/bin/bash
# Builds "Wallpaper Studio.app" next to this script.
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"  signs with your identity + hardened runtime (otherwise ad-hoc).
set -euo pipefail
cd "$(dirname "$0")"
APP="Wallpaper Studio.app"
VERSION="$(tr -d '[:space:]' < VERSION)"
BUILD="$(git rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)"

swift build -c release --product WallpaperStudio
BIN="$(swift build -c release --show-bin-path)/WallpaperStudio"

rm -rf "$APP" "Live Wallpaper.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WallpaperStudio"
# SwiftPM stamps the binary as built against the minimum SDK (14.0). macOS decides whether an app gets the current system design
# (Liquid Glass sidebar, window and controls) from the SDK stamp, so record the real SDK the app was compiled against. The
# minimum OS stays 14.0; the glass code is guarded by #available(macOS 26, *). Must run before codesign.
SDK_VERSION="$(xcrun --show-sdk-version 2>/dev/null || true)"
if [ -n "$SDK_VERSION" ] && command -v vtool >/dev/null; then
  vtool -set-build-version macos 14.0 "$SDK_VERSION" -replace -output "$APP/Contents/MacOS/WallpaperStudio" "$APP/Contents/MacOS/WallpaperStudio" >/dev/null 2>&1 || echo "note: could not restamp the SDK version"
fi
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Wallpaper Studio</string>
<key>CFBundleDisplayName</key><string>Wallpaper Studio</string>
<key>CFBundleIdentifier</key><string>com.local.livewallpaper</string>
<key>CFBundleExecutable</key><string>WallpaperStudio</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$VERSION</string>
<key>CFBundleVersion</key><string>$BUILD</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
<key>NSHumanReadableCopyright</key><string>Wallpaper Studio $VERSION</string>
<key>NSMicrophoneUsageDescription</key><string>Wallpaper Studio listens to the microphone only if you choose it as the audio source for music-reactive wallpapers. Nothing is recorded or stored.</string>
<key>CFBundleURLTypes</key><array><dict>
  <key>CFBundleURLName</key><string>Wallpaper Studio commands</string>
  <key>CFBundleURLSchemes</key><array><string>wallpaperstudio</string></array>
</dict></array>
<key>UTExportedTypeDeclarations</key><array>
  <dict>
    <key>UTTypeIdentifier</key><string>com.local.wallpaperstudio.package</string>
    <key>UTTypeDescription</key><string>Wallpaper Studio Package</string>
    <key>UTTypeConformsTo</key><array><string>public.data</string><string>public.archive</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>wsp</string></array></dict>
  </dict>
  <dict>
    <key>UTTypeIdentifier</key><string>com.local.wallpaperstudio.scene</string>
    <key>UTTypeDescription</key><string>Wallpaper Studio Scene</string>
    <key>UTTypeConformsTo</key><array><string>public.json</string></array>
    <key>UTTypeTagSpecification</key><dict><key>public.filename-extension</key><array><string>wsscene</string></array></dict>
  </dict>
</array>
<key>CFBundleDocumentTypes</key><array>
  <dict>
    <key>CFBundleTypeName</key><string>Wallpaper Studio wallpaper</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Owner</string>
    <key>LSItemContentTypes</key><array><string>com.local.wallpaperstudio.package</string><string>com.local.wallpaperstudio.scene</string></array>
  </dict>
  <dict>
    <key>CFBundleTypeName</key><string>Media wallpaper</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.movie</string><string>public.image</string></array>
  </dict>
</array>
</dict></plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --options runtime --timestamp --entitlements Resources/Entitlements.plist --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP"
fi
echo "Built: $PWD/$APP  (version $VERSION, build $BUILD, $( [ -n "${SIGN_IDENTITY:-}" ] && echo "signed: $SIGN_IDENTITY" || echo "ad-hoc signed" ))"
