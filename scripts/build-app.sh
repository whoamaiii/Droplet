#!/bin/bash
# Builds a new local bundle without touching Applications, launchd or running apps.
set -euo pipefail
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG=release
PREVIEW=0
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=debug ;;
        --preview) PREVIEW=1 ;;
        *) echo "Usage: $0 [--debug] [--preview]" >&2; exit 64 ;;
    esac
done
cd "$SRC_DIR"
BUILD_ARGS=(--configuration "$CONFIG" --product Droplet --arch arm64)
if [ "$PREVIEW" = 1 ]; then BUILD_ARGS+=(-Xswiftc -DDROPLET_PREVIEW); fi
swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build --configuration "$CONFIG" --arch arm64 --show-bin-path)"
# Documents may be managed by iCloud/FileProvider, which adds FinderInfo to
# .app directories and invalidates strict signing checks. Stage outside sync.
BUILD_ROOT="${DROPLET_BUILD_ROOT:-$HOME/Library/Developer/Droplet/Builds}"
mkdir -p "$BUILD_ROOT"
OUTPUT="$(mktemp -d "$BUILD_ROOT/local.XXXXXXXX")"
COMPLETE=0
trap 'if [ "$COMPLETE" != 1 ]; then rm -rf "$OUTPUT"; fi' EXIT
APP="$OUTPUT/Droplet.app"
mkdir -p "$APP/Contents/MacOS"
cp -X "$BIN_DIR/Droplet" "$APP/Contents/MacOS/Droplet"
cp -X "$SRC_DIR/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
if [ "$PREVIEW" = 1 ]; then
    /usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.quentinthiessen.droplet.preview' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName Droplet Preview' "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c 'Add :DropletIsPreview bool true' "$APP/Contents/Info.plist"
    if [ -n "${DROPLET_PREVIEW_URL:-}" ] && [ -n "${DROPLET_PREVIEW_DOWNLOADS:-}" ]; then
        /usr/libexec/PlistBuddy -c "Add :DropletPreviewURL string $DROPLET_PREVIEW_URL" "$APP/Contents/Info.plist"
        /usr/libexec/PlistBuddy -c "Add :DropletPreviewDownloads string $DROPLET_PREVIEW_DOWNLOADS" "$APP/Contents/Info.plist"
    fi
fi
plutil -lint "$APP/Contents/Info.plist"
# Local development only. WHO-237 adds Developer ID/notarization for customers.
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
COMPLETE=1
echo "Local build (ad-hoc signed; NOT a public release): $APP"
