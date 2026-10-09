#!/bin/zsh
# Runs the unit tests with the Command Line Tools toolchain.
# The testing macro plugin needs an explicit path after a release build.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
export SDKROOT="${SDKROOT:-/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk}"
PLUGINS=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
swift build --package-path "$ROOT" --build-tests -Xswiftc -plugin-path -Xswiftc "$PLUGINS"
swift test --package-path "$ROOT" --skip-build "$@"
