#!/bin/bash
# Compile and sign before disrupting the installed app; install only completed files.
set -euo pipefail
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Droplet.app"
BIN="$APP/Contents/MacOS/Droplet"
LABEL="com.quentinthiessen.droplet"
DOMAIN="gui/$(id -u)"
JOB="$DOMAIN/$LABEL"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE="$HOME/Library/Application Support/Droplet/running.plist"
CHECK=0; LAUNCH=1; LOGIN=preserve
for arg in "$@"; do
    case "$arg" in
        --check) CHECK=1 ;;
        --no-launch) LAUNCH=0 ;;
        --login) LOGIN=on ;;
        --no-login) LOGIN=off ;;
        *) echo "Usage: bash build.sh [--check] [--no-launch] [--login|--no-login]" >&2; exit 2 ;;
    esac
done
[[ "$(uname -s)" == Darwin ]] || { echo "Building Droplet requires macOS 14+ and Xcode Command Line Tools." >&2; exit 1; }
ARCH="$(uname -m)"
[[ "$ARCH" == arm64 || "$ARCH" == x86_64 ]] || { echo "Unsupported architecture: $ARCH" >&2; exit 1; }
WORK="$(mktemp -d "${TMPDIR:-/tmp}/droplet-build.XXXXXX")"
LOCK=""; STAGED=""; BACKUP=""; OLD_AGENT=0; OLD_LOADED=0
CHANGED=0; SWAPPED=0; OLD_MOVED=0; COMMITTED=0

instance_pids() {
    # Exact executable path, not a substring search for Droplet/ffmpeg/yt-dlp.
    ps -axo pid=,comm= | while read -r pid executable; do
        if [[ "$executable" == "$BIN" ]]; then printf '%s\n' "$pid"; fi
    done
}
stop_instances() {
    local pid remaining iteration
    remaining="$(instance_pids)"
    for pid in $remaining; do
        if [[ "$(ps -p "$pid" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//')" == "$BIN" ]]; then
            kill -TERM "$pid" 2>/dev/null || true
        fi
    done
    for iteration in {1..100}; do
        remaining="$(instance_pids)"
        [[ -n "$remaining" ]] || return 0
        sleep 0.1
    done
    echo "Droplet did not stop cleanly; refusing to replace a live executable." >&2
    return 1
}
cleanup() {
    local result=$?
    trap - EXIT INT TERM
    if [[ "$CHANGED" == 1 && "$COMMITTED" == 0 ]]; then
        echo "Install did not complete; restoring the previous installation." >&2
        /bin/launchctl bootout "$JOB" >/dev/null 2>&1 || true
        stop_instances || { echo "Could not stop replacement; backup retained at $BACKUP" >&2; exit 1; }
        if [[ "$SWAPPED" == 1 ]]; then rm -rf "$APP"; fi
        if [[ "$OLD_MOVED" == 1 ]]; then
            if [[ ! -d "$BACKUP" ]] || ! mv "$BACKUP" "$APP"; then
                echo "Automatic restore failed. Previous bundle, if present, is retained at $BACKUP" >&2
                echo "Installer state is retained at $WORK; resolve the restore before removing $LOCK." >&2
                exit 1
            fi
        fi
        if [[ "$OLD_AGENT" == 1 ]]; then cp "$WORK/previous-agent.plist" "$AGENT"
        else rm -f "$AGENT"; fi
        if [[ "$OLD_LOADED" == 1 && -f "$AGENT" ]]; then
            /bin/launchctl bootstrap "$DOMAIN" "$AGENT" >/dev/null 2>&1 || true
        elif [[ -n "${OLD_PIDS:-}" && -d "$APP" ]]; then
            open "$APP" || true
        fi
    fi
    [[ -z "$STAGED" ]] || rm -rf "$STAGED"
    [[ -z "$LOCK" ]] || rmdir "$LOCK" 2>/dev/null || true
    rm -rf "$WORK"
    exit "$result"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Failure here leaves the existing app and agent untouched.
BUILT="$WORK/Droplet.app"
mkdir -p "$BUILT/Contents/MacOS"
cp "$SRC_DIR/Info.plist" "$BUILT/Contents/Info.plist"
BUILD_ID="$(uuidgen)"
plutil -insert DropletBuildID -string "$BUILD_ID" "$BUILT/Contents/Info.plist"
printf 'APPL????' > "$BUILT/Contents/PkgInfo"
TARGET="$ARCH-apple-macos14.0"
xcrun clang -O2 -target "$TARGET" -std=c11 -Wall -Wextra -Werror \
    -c "$SRC_DIR/ProcessSupport.c" -o "$WORK/ProcessSupport.o"
xcrun swiftc -O -swift-version 5 -warnings-as-errors -parse-as-library -target "$TARGET" \
    -import-objc-header "$SRC_DIR/ProcessSupport.h" \
    "$SRC_DIR/main.swift" "$SRC_DIR/DownloadCore.swift" "$SRC_DIR/ProcessRuntime.swift" \
    "$WORK/ProcessSupport.o" -o "$BUILT/Contents/MacOS/Droplet"
plutil -lint "$BUILT/Contents/Info.plist" "$SRC_DIR/com.quentinthiessen.droplet.plist"
codesign --force --sign - "$BUILT"
codesign --verify --strict "$BUILT"
if [[ "$CHECK" == 1 ]]; then
    echo "Build, plist and signature checks passed ($ARCH). Nothing installed or launched."
    exit 0
fi

mkdir -p "$HOME/Applications" "$HOME/Library/LaunchAgents"
LOCK="$HOME/Applications/.droplet-install-lock"
if ! mkdir "$LOCK" 2>/dev/null; then
    echo "Another install holds $LOCK. After a forcibly killed build, confirm no build is running before removing that empty directory." >&2
    LOCK=""; exit 1
fi
STAGED="$(mktemp -d "$HOME/Applications/.droplet-stage.XXXXXX")"
ditto "$BUILT" "$STAGED/Droplet.app"
BACKUP="$STAGED/Previous-Droplet.app"
OLD_PIDS="$(instance_pids)"
# The legacy Quit sweeps unrelated jobs; its SIGTERM does not clean owned workers.
# Require that legacy instance to be idle rather than invoke either unsafe path.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null || echo 0)"
if [[ "$VERSION" == 1 ]]; then
    for pid in $OLD_PIDS; do
        if pgrep -P "$pid" >/dev/null 2>&1; then
            echo "Legacy Droplet has a running download/update. Cancel it (or let the update finish), then rebuild. Do not use the legacy Quit button." >&2
            exit 1
        fi
    done
fi
[[ ! -f "$AGENT" ]] || { OLD_AGENT=1; cp "$AGENT" "$WORK/previous-agent.plist"; }
if /bin/launchctl print "$JOB" >/dev/null 2>&1; then OLD_LOADED=1; fi
WANT_LOGIN="$OLD_AGENT"
[[ "$LOGIN" != on ]] || WANT_LOGIN=1
[[ "$LOGIN" != off ]] || WANT_LOGIN=0

CHANGED=1
if [[ "$OLD_LOADED" == 1 ]]; then /bin/launchctl bootout "$JOB"; fi
stop_instances
# Agent is unloaded; same-filesystem renames install a fully signed bundle.
if [[ -d "$APP" ]]; then mv "$APP" "$BACKUP"; OLD_MOVED=1; fi
mv "$STAGED/Droplet.app" "$APP"; SWAPPED=1
if [[ "$WANT_LOGIN" == 1 ]]; then
    cp "$SRC_DIR/com.quentinthiessen.droplet.plist" "$WORK/new-agent.plist"
    plutil -replace ProgramArguments.0 -string "$BIN" "$WORK/new-agent.plist"
    plutil -lint "$WORK/new-agent.plist"
    AGENT_TEMP="$(mktemp "$HOME/Library/LaunchAgents/.droplet.XXXXXX")"
    cp "$WORK/new-agent.plist" "$AGENT_TEMP"
    chmod 644 "$AGENT_TEMP"
    mv "$AGENT_TEMP" "$AGENT"
else
    rm -f "$AGENT"
fi
LSREG="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
"$LSREG" -f "$APP" >/dev/null 2>&1 || true
if [[ "$LAUNCH" == 1 ]]; then
    if [[ "$WANT_LOGIN" == 1 ]]; then /bin/launchctl bootstrap "$DOMAIN" "$AGENT"
    else open "$APP"; fi
    READY=0
    for iteration in {1..100}; do
        RUNNING_BUILD="$(plutil -extract build raw -o - "$STATE" 2>/dev/null || true)"
        RUNNING_PID="$(plutil -extract pid raw -o - "$STATE" 2>/dev/null || true)"
        if [[ "$RUNNING_BUILD" == "$BUILD_ID" && "$RUNNING_PID" =~ ^[0-9]+$ ]] &&
           [[ "$(ps -p "$RUNNING_PID" -o comm= 2>/dev/null | sed 's/^[[:space:]]*//')" == "$BIN" ]]; then
            READY=1; break
        fi
        sleep 0.1
    done
    [[ "$READY" == 1 ]] || { echo "The newly built app did not report ready. Restoring the old installation." >&2; exit 1; }
    echo "Built and verified running: $APP (build $BUILD_ID, PID $RUNNING_PID)"
else
    echo "Built and installed: $APP (not launched)."
fi
COMMITTED=1
if [[ "$OLD_MOVED" == 1 ]]; then rm -rf "$BACKUP"; fi
if [[ "$WANT_LOGIN" == 1 ]]; then
    echo "Login agent installed. Do not also add Droplet as a separate Login Item."
fi
