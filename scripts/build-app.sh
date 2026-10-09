#!/bin/zsh
# Build the app bundle with SwiftPM. Xcode is not required.
# Usage: scripts/build-app.sh [debug|release]
set -euo pipefail
setopt null_glob

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-release}"
# The macOS 27 SDK needs a SwiftUI macro plugin that only Xcode ships. Use the 26.5 SDK.
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
APP_NAME="Apple TV Remote"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

swift build -c "$CONFIG" --product RemoteApp --package-path "$ROOT"

BIN="$ROOT/.build/$CONFIG/RemoteApp"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/RemoteApp"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
echo -n "APPL????" > "$APP/Contents/PkgInfo"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
    cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi

# SwiftPM puts target resources in a bundle next to the binary. Copy it when it exists.
for bundle in "$ROOT/.build/$CONFIG"/RemoteApp_*.bundle; do
    [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

# Ad-hoc signature. A Developer ID signature comes from scripts/notarize.sh.
codesign --force --sign - --timestamp=none "$APP"

echo "Built: $APP"
