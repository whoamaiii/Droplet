#!/bin/bash
# Builds the customer download: a Developer ID-signed, notarized and stapled
# Droplet.app (universal by default) inside a signed, notarized DMG, plus a
# SHA-256 file for the website.
#
#   cp release.env.example release.env      # fill in once; it is git-ignored
#   ./scripts/release.sh [path/to/release.env]
#
# One-time Apple and store setup: docs/release/RELEASE.md
set -euo pipefail
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-$SRC_DIR/release.env}"

fail() { echo "release: $*" >&2; exit 1; }
[ -f "$CONFIG" ] || fail "missing $CONFIG — copy release.env.example to release.env and fill it in"
set -a
# shellcheck disable=SC1090
. "$CONFIG"
set +a

# ---------------------------------------------------------------- validate
DROPLET_ARCH="${DROPLET_ARCH:-universal}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"
[ -n "${DROPLET_BUNDLE_ID:-}" ] || fail "DROPLET_BUNDLE_ID is required (for example com.yourdomain.droplet)"
[[ "$DROPLET_BUNDLE_ID" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || fail "DROPLET_BUNDLE_ID must be reverse-DNS"
case "$DROPLET_BUNDLE_ID" in
    local.*|*.example.*|com.example*|*.preview) fail "DROPLET_BUNDLE_ID must be your own permanent identifier, not $DROPLET_BUNDLE_ID" ;;
esac
[[ "${DROPLET_VERSION:-}" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || fail "DROPLET_VERSION must look like 1.0 or 1.0.1"
[[ "${DROPLET_BUILD:-}" =~ ^[0-9]+$ ]] || fail "DROPLET_BUILD must be a whole number that increases every release"
case "$DROPLET_ARCH" in
    universal) ARCHS=(arm64 x86_64) ;;
    arm64|x86_64) ARCHS=("$DROPLET_ARCH") ;;
    *) fail "DROPLET_ARCH must be universal, arm64 or x86_64" ;;
esac
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"
[ -n "$IDENTITY" ] || fail "DEVELOPER_ID_APPLICATION is required (\"Developer ID Application: Name (TEAMID)\", or - for an unsigned test build)"
if [ "$IDENTITY" = "-" ]; then
    SKIP_NOTARIZE=1
    echo "release: ad-hoc test build — NOT for customers (Gatekeeper will block it)" >&2
else
    [[ "$IDENTITY" == "Developer ID Application:"* ]] || fail "DEVELOPER_ID_APPLICATION must be a \"Developer ID Application: …\" identity"
    [ "$SKIP_NOTARIZE" = 1 ] || [ -n "${NOTARY_PROFILE:-}" ] || fail "NOTARY_PROFILE is required (xcrun notarytool store-credentials)"
fi
https_url() { [[ "$1" =~ ^https://[A-Za-z0-9.-]+(/[^[:space:]]*)?$ ]]; }
if [ "${ALLOW_UNLICENSED:-0}" != 1 ]; then
    [[ "${DROPLET_LS_STORE_ID:-}" =~ ^[0-9]+$ ]] || fail "DROPLET_LS_STORE_ID (numeric Lemon Squeezy store ID) is required; without it the trial ends with no way to buy"
    [[ "${DROPLET_LS_PRODUCT_ID:-}" =~ ^[0-9]+$ ]] || fail "DROPLET_LS_PRODUCT_ID (numeric) is required"
    [ -z "${DROPLET_LS_VARIANT_ID:-}" ] || [[ "$DROPLET_LS_VARIANT_ID" =~ ^[0-9]+$ ]] || fail "DROPLET_LS_VARIANT_ID must be numeric or empty"
    https_url "${DROPLET_CHECKOUT_URL:-}" || fail "DROPLET_CHECKOUT_URL must be your https checkout link"
fi
https_url "${DROPLET_WEBSITE_URL:-}" || fail "DROPLET_WEBSITE_URL must be an https URL"
https_url "${DROPLET_PRIVACY_URL:-}" || fail "DROPLET_PRIVACY_URL must be an https URL (a privacy policy is required for selling)"
SUPPORT="${DROPLET_SUPPORT:-}"
https_url "$SUPPORT" || [[ "$SUPPORT" =~ ^(mailto:)?[^@[:space:]/?]+@[^@[:space:]/?]+\.[A-Za-z]+$ ]] || fail "DROPLET_SUPPORT must be an email address or https URL"
ENGINE_VERSION="$(python3 "$SRC_DIR/scripts/fetch_engine.py" --print-version)"
[ -n "$ENGINE_VERSION" ] || fail "the engine is not pinned — run: python3 scripts/fetch_engine.py --pin --yt-dlp latest --deno latest --ffmpeg"
if [ "${VALIDATE_ONLY:-0}" = 1 ]; then echo "release: configuration OK"; exit 0; fi

for tool in swift lipo codesign hdiutil ditto plutil xcrun spctl shasum xattr; do
    command -v "$tool" >/dev/null || fail "$tool is missing (install Xcode or the Command Line Tools)"
done
if [ "$IDENTITY" != "-" ]; then
    security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\"" \
        || fail "signing identity not found in your keychain: $IDENTITY"
fi

# ---------------------------------------------------------------- build
cd "$SRC_DIR"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/droplet-release.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BINS=()
for arch in "${ARCHS[@]}"; do
    swift build --configuration release --product Droplet --arch "$arch"
    BINS+=("$(swift build --configuration release --arch "$arch" --show-bin-path)/Droplet")
done

APP="$WORK/Droplet.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/Droplet"
cp -X "$SRC_DIR/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"
cp -X "$SRC_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/ThirdPartyNotices"
cp -X "$SRC_DIR/Resources/ThirdPartyNotices/"* "$APP/Contents/Resources/ThirdPartyNotices/"
python3 "$SRC_DIR/scripts/fetch_engine.py" --arch "$DROPLET_ARCH" \
    --output "$APP/Contents/Helpers" --notices "$APP/Contents/Resources/ThirdPartyNotices"

PLIST="$APP/Contents/Info.plist"
set_key() { plutil -replace "$1" -string "$2" "$PLIST"; }
set_key CFBundleIdentifier "$DROPLET_BUNDLE_ID"
set_key CFBundleShortVersionString "$DROPLET_VERSION"
set_key CFBundleVersion "$DROPLET_BUILD"
set_key NSHumanReadableCopyright "${DROPLET_COPYRIGHT:-}"
set_key DropletBundledEngineVersion "$ENGINE_VERSION"
set_key DropletLicenseStoreID "${DROPLET_LS_STORE_ID:-}"
set_key DropletLicenseProductID "${DROPLET_LS_PRODUCT_ID:-}"
set_key DropletLicenseVariantID "${DROPLET_LS_VARIANT_ID:-}"
set_key DropletCheckoutURL "${DROPLET_CHECKOUT_URL:-}"
set_key DropletSupportURL "$SUPPORT"
set_key DropletWebsiteURL "$DROPLET_WEBSITE_URL"
set_key DropletPrivacyURL "$DROPLET_PRIVACY_URL"
plutil -lint "$PLIST"

# ---------------------------------------------------------------- sign
xattr -cr "$APP"
if [ "$IDENTITY" = "-" ]; then TIMESTAMP=(--timestamp=none); else TIMESTAMP=(--timestamp); fi
sign() { codesign --force "${TIMESTAMP[@]}" --options runtime --sign "$IDENTITY" "$@"; }
for helper in "$APP/Contents/Helpers/"*; do
    entitlements="$SRC_DIR/Resources/Entitlements/$(basename "$helper").entitlements"
    if [ -f "$entitlements" ]; then sign --entitlements "$entitlements" "$helper"; else sign "$helper"; fi
done
sign "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

notarize() {
    local file="$1" result
    result="$WORK/notary-$(basename "$1").json"
    echo "Notarizing $(basename "$file") (this usually takes a few minutes)…"
    xcrun notarytool submit "$file" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 2h \
        --output-format json > "$result" || true
    local status id
    status="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("status",""))' "$result" 2>/dev/null || true)"
    id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("id",""))' "$result" 2>/dev/null || true)"
    if [ "$status" != "Accepted" ]; then
        echo "release: notarization of $(basename "$file") returned '${status:-no status}'" >&2
        if [ -n "$id" ]; then xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
        else cat "$result" >&2; fi
        exit 1
    fi
}

if [ "$SKIP_NOTARIZE" != 1 ]; then
    ditto -c -k --keepParent "$APP" "$WORK/Droplet.zip"
    notarize "$WORK/Droplet.zip"
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=4 "$APP"
fi

# ---------------------------------------------------------------- DMG
DIST="${DROPLET_DIST_DIR:-$SRC_DIR/dist}"
mkdir -p "$DIST"
DMG="$DIST/Droplet-$DROPLET_VERSION.dmg"
STAGE="$WORK/dmg"
mkdir "$STAGE"
ditto "$APP" "$STAGE/Droplet.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG" "$DMG.sha256"
hdiutil create -volname "Droplet" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
if [ "$IDENTITY" != "-" ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
if [ "$SKIP_NOTARIZE" != 1 ]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
fi
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

echo
echo "Release ready:"
echo "  $DMG"
echo "  $(cat "$DMG.sha256")"
echo "  bundle id $DROPLET_BUNDLE_ID, version $DROPLET_VERSION ($DROPLET_BUILD), engine yt-dlp $ENGINE_VERSION, ${ARCHS[*]}"
if [ "$SKIP_NOTARIZE" = 1 ]; then echo "  NOT notarized — for testing only, do not publish."; fi
