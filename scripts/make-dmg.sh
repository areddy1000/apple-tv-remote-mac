#!/bin/zsh
# Builds the release app and wraps it in a DMG. No signing identity is needed.
# The app inside is ad-hoc signed. Use scripts/notarize.sh when a Developer ID exists.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/dist/Apple TV Remote.app"
DMG="$ROOT/dist/AppleTVRemote.dmg"
STAGE="$ROOT/dist/dmg-stage"

"$ROOT/scripts/build-app.sh" release

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Apple TV Remote" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"
rm -rf "$STAGE"
echo "Wrote: $DMG"
