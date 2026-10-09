#!/bin/zsh
# Sign with a Developer ID, notarize, staple and build a DMG.
# Needs: a "Developer ID Application" identity in the keychain and a notarytool profile.
# Set up the profile once:
#   xcrun notarytool store-credentials AppleTVRemote --apple-id you@example.com --team-id TEAMID
# Usage: scripts/notarize.sh "Developer ID Application: Name (TEAMID)" [AppleTVRemote]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${1:?Developer ID identity is required}"
PROFILE="${2:-AppleTVRemote}"
APP="$ROOT/dist/Apple TV Remote.app"
DMG="$ROOT/dist/AppleTVRemote.dmg"

"$ROOT/scripts/build-app.sh" release

codesign --force --options runtime --timestamp \
    --entitlements "$ROOT/Resources/Release.entitlements" \
    --sign "$IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

rm -f "$DMG"
hdiutil create -volname "Apple TV Remote" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --force --timestamp --sign "$IDENTITY" "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler staple "$APP"
echo "Notarized: $DMG"
