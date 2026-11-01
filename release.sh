#!/bin/bash
# Builds, signs and packages a distributable disk image: dist/Wallpaper-Studio-<version>.dmg
#
#   ./release.sh                       ad-hoc signed DMG for local use (Gatekeeper will ask to confirm on first open)
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./release.sh
#                                      signed with the hardened runtime
#   ... NOTARY_PROFILE=my-profile ./release.sh
#                                      also notarises and staples (profile created once with:
#                                      xcrun notarytool store-credentials my-profile --apple-id … --team-id … --password …)
set -euo pipefail
cd "$(dirname "$0")"
VERSION="$(tr -d '[:space:]' < VERSION)"
APP="Wallpaper Studio.app"
DMG="dist/Wallpaper-Studio-$VERSION.dmg"

./test.sh >/dev/null 2>&1 && echo "tests: passed" || { echo "tests FAILED; aborting release"; exit 1; }
./build.sh

mkdir -p dist
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -quiet -volname "Wallpaper Studio $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

if [ -n "${SIGN_IDENTITY:-}" ]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
fi
if [ -n "${NOTARY_PROFILE:-}" ]; then
  [ -n "${SIGN_IDENTITY:-}" ] || { echo "notarisation needs SIGN_IDENTITY"; exit 1; }
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
fi

echo "---"
echo "Disk image: $PWD/$DMG"
shasum -a 256 "$DMG"
codesign --verify --deep --strict "$APP" && echo "app signature: valid"
