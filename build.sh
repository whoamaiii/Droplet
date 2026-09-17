#!/bin/bash
# Rebuild & relaunch Droplet.
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Droplet.app"
BIN="$APP/Contents/MacOS/Droplet"

pkill -x Droplet 2>/dev/null || true
sleep 0.3

mkdir -p "$APP/Contents/MacOS"
cp "$SRC_DIR/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -o "$BIN" "$SRC_DIR/main.swift"
xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - "$APP"

# refresh Launch Services registration (prevents stale-record -10825 errors)
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREG" -u "$APP" 2>/dev/null || true
"$LSREG" -f "$APP" 2>/dev/null || true

open "$APP"
echo "✔ Built & launched $APP"
