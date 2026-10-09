#!/bin/bash
# Builds the customer download for your website (never the App Store):
#
# - With a "Developer ID Application" identity (paid Apple account): a signed,
#   notarized and stapled app in a notarized DMG. Opens with a double-click.
# - With any other identity — a free self-signed certificate, a free
#   "Apple Development" certificate, or "-" — a "direct" build: a zip plus an
#   install.sh that customers run with one Terminal line, and a DMG for those
#   who prefer System Settings → Privacy & Security → Open Anyway.
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
# Patterns live in variables: macOS's bash 3.2 cannot parse parentheses
# written directly inside [[ =~ ]].
RE_BUNDLE_ID='^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$'
RE_VERSION='^[0-9]+\.[0-9]+(\.[0-9]+)?$'
RE_NUMBER='^[0-9]+$'
RE_HTTPS='^https://[A-Za-z0-9.-]+(/[^[:space:]]*)?$'
RE_DOWNLOAD_URL='^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~%/+-]*)?$'
RE_EMAIL='^(mailto:)?[^@[:space:]/?]+@[^@[:space:]/?]+\.[A-Za-z]+$'
RE_GITHUB_REPO='^[A-Za-z0-9-]+/[A-Za-z0-9._-]+$'
RE_PRICE='^US\$([1-9][0-9]{0,2}(\.[0-9]{2})?|0\.(0[1-9]|[1-9][0-9]))$'
RE_LAUNCH_CHECKOUT='^https://[A-Za-z0-9.-]+(/[A-Za-z0-9._~%/+-]*)?$'
DROPLET_ARCH="${DROPLET_ARCH:-universal}"
SKIP_NOTARIZE="${SKIP_NOTARIZE:-0}"
[ -n "${DROPLET_BUNDLE_ID:-}" ] || fail "DROPLET_BUNDLE_ID is required (for example com.yourdomain.droplet)"
[[ "$DROPLET_BUNDLE_ID" =~ $RE_BUNDLE_ID ]] || fail "DROPLET_BUNDLE_ID must be reverse-DNS"
case "$DROPLET_BUNDLE_ID" in
    local.*|*.example.*|com.example*|*.preview) fail "DROPLET_BUNDLE_ID must be your own permanent identifier, not $DROPLET_BUNDLE_ID" ;;
esac
[[ "${DROPLET_VERSION:-}" =~ $RE_VERSION ]] || fail "DROPLET_VERSION must look like 1.0 or 1.0.1"
[[ "${DROPLET_BUILD:-}" =~ $RE_NUMBER ]] || fail "DROPLET_BUILD must be a whole number that increases every release"
case "$DROPLET_ARCH" in
    universal) ARCHS=(arm64 x86_64) ;;
    arm64|x86_64) ARCHS=("$DROPLET_ARCH") ;;
    *) fail "DROPLET_ARCH must be universal, arm64 or x86_64" ;;
esac
https_url() { [[ "$1" =~ $RE_HTTPS ]]; }
IDENTITY="${SIGNING_IDENTITY:-${DEVELOPER_ID_APPLICATION:-}}"
[ -n "$IDENTITY" ] || fail "SIGNING_IDENTITY is required: the name of your free self-signed certificate (docs/release/RELEASE.md), a \"Developer ID Application: …\" identity, or -"
if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
    MODE=notarized
    [ "$SKIP_NOTARIZE" = 1 ] || [ -n "${NOTARY_PROFILE:-}" ] || fail "NOTARY_PROFILE is required (xcrun notarytool store-credentials)"
else
    MODE=direct
    SKIP_NOTARIZE=1
    if [ "$IDENTITY" = "-" ]; then
        echo "release: unsigned (ad-hoc) build — macOS will ask customers again for folder and Keychain access after every update; a free self-signed certificate avoids that (see docs/release/RELEASE.md)" >&2
    fi
fi
DOWNLOAD_URL="${DROPLET_DOWNLOAD_URL:-}"
DOWNLOAD_URL="${DOWNLOAD_URL%/}"
if [ "$MODE" = direct ]; then
    https_url "$DOWNLOAD_URL" || fail "DROPLET_DOWNLOAD_URL is required without a Developer ID: the https folder on your website where you upload Droplet's zip (the install command downloads from it)"
elif [ -n "$DOWNLOAD_URL" ]; then
    https_url "$DOWNLOAD_URL" || fail "DROPLET_DOWNLOAD_URL must be an https URL"
fi
[ -z "$DOWNLOAD_URL" ] || [[ "$DOWNLOAD_URL" =~ $RE_DOWNLOAD_URL ]] \
    || fail "DROPLET_DOWNLOAD_URL may only use letters, digits and . _ ~ % / + - (it is pasted into the install command)"
case "$DOWNLOAD_URL" in *"/."*) fail "DROPLET_DOWNLOAD_URL folders may not start with a dot" ;; esac
# Free hosting on GitHub: the website (with install.sh) on GitHub Pages, the
# zip and DMG on a GitHub release of the same public repository.
GITHUB_REPO="${DROPLET_GITHUB_REPO:-}"
FILES_URL="$DOWNLOAD_URL"
if [ -n "$GITHUB_REPO" ]; then
    [[ "$GITHUB_REPO" =~ $RE_GITHUB_REPO ]] || fail "DROPLET_GITHUB_REPO must look like yourname/yourname.github.io"
    [ -n "$DOWNLOAD_URL" ] || fail "DROPLET_DOWNLOAD_URL is required with DROPLET_GITHUB_REPO"
    PAGES_BASE="$("$SRC_DIR/scripts/github_pages.sh" base "$GITHUB_REPO")"
    case "$DOWNLOAD_URL" in
        "$PAGES_BASE"|"$PAGES_BASE"/*) ;;
        *) fail "with DROPLET_GITHUB_REPO=$GITHUB_REPO, DROPLET_DOWNLOAD_URL must be $PAGES_BASE or a folder in it, for example $PAGES_BASE/droplet" ;;
    esac
    FILES_URL="https://github.com/$GITHUB_REPO/releases/download/v$DROPLET_VERSION"
fi
if [ "${ALLOW_UNLICENSED:-0}" != 1 ]; then
    [[ "${DROPLET_LS_STORE_ID:-}" =~ $RE_NUMBER ]] || fail "DROPLET_LS_STORE_ID (numeric Lemon Squeezy store ID) is required; without it the trial ends with no way to buy"
    [[ "${DROPLET_LS_PRODUCT_ID:-}" =~ $RE_NUMBER ]] || fail "DROPLET_LS_PRODUCT_ID (numeric) is required"
    [ -z "${DROPLET_LS_VARIANT_ID:-}" ] || [[ "$DROPLET_LS_VARIANT_ID" =~ $RE_NUMBER ]] || fail "DROPLET_LS_VARIANT_ID must be numeric or empty"
    https_url "${DROPLET_CHECKOUT_URL:-}" || fail "DROPLET_CHECKOUT_URL must be your https checkout link"
fi
https_url "${DROPLET_WEBSITE_URL:-}" || fail "DROPLET_WEBSITE_URL must be an https URL"
https_url "${DROPLET_PRIVACY_URL:-}" || fail "DROPLET_PRIVACY_URL must be an https URL (a privacy policy is required for selling)"
SUPPORT="${DROPLET_SUPPORT:-}"
https_url "$SUPPORT" || [[ "$SUPPORT" =~ $RE_EMAIL ]] || fail "DROPLET_SUPPORT must be an email address or https URL"
if [ -n "$DOWNLOAD_URL" ]; then
    # The download website is built from these (scripts/build_site.py).
    [ -n "${DROPLET_OWNER:-}" ] || fail "DROPLET_OWNER is required: your name or company, shown as the seller on the website"
    [[ "${DROPLET_REFUND_DAYS:-14}" =~ $RE_NUMBER ]] || fail "DROPLET_REFUND_DAYS must be a number of days"
    case "${DROPLET_LAUNCH_OFFER:-0}" in
        0) ;;
        1) [[ "${DROPLET_PRICE:-}" =~ $RE_PRICE ]] \
               || fail "DROPLET_LAUNCH_OFFER=1 needs DROPLET_PRICE like 'US\$4.99' (in single quotes): customers choose a price from US\$0 up to it" ;;
        *) fail "DROPLET_LAUNCH_OFFER must be 1 (customers choose a price from US\$0 up to DROPLET_PRICE) or 0" ;;
    esac
    [ -z "${DROPLET_LAUNCH_CHECKOUT_URL:-}" ] || [[ "$DROPLET_LAUNCH_CHECKOUT_URL" =~ $RE_LAUNCH_CHECKOUT ]] \
        || fail "DROPLET_LAUNCH_CHECKOUT_URL must be an https address without ? or #: it receives the chosen price as ?price=2.50"
fi
ENGINE_VERSION="$(python3 "$SRC_DIR/scripts/fetch_engine.py" --print-version)"
[ -n "$ENGINE_VERSION" ] || fail "the engine is not pinned — run: python3 scripts/fetch_engine.py --pin --yt-dlp latest --deno latest --ffmpeg"
if [ "${VALIDATE_ONLY:-0}" = 1 ]; then echo "release: configuration OK"; exit 0; fi

for tool in swift lipo codesign hdiutil ditto plutil xcrun spctl shasum xattr; do
    command -v "$tool" >/dev/null || fail "$tool is missing (install Xcode or the Command Line Tools)"
done
if [ "$MODE" = notarized ]; then
    security find-identity -v -p codesigning | grep -qF "\"$IDENTITY\"" \
        || fail "signing identity not found in your keychain: $IDENTITY"
elif [ "$IDENTITY" != "-" ]; then
    # Self-signed certificates are not "valid" (trusted) identities, so no -v.
    security find-identity -p codesigning | grep -qF "\"$IDENTITY\"" \
        || fail "signing certificate not found in your keychain: $IDENTITY"
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
if [ "$MODE" = notarized ]; then
    # Hardened runtime and secure timestamps are what notarization requires.
    sign() { codesign --force --timestamp --options runtime --sign "$IDENTITY" "$@"; }
    for helper in "$APP/Contents/Helpers/"*; do
        entitlements="$SRC_DIR/Resources/Entitlements/$(basename "$helper").entitlements"
        if [ -f "$entitlements" ]; then sign --entitlements "$entitlements" "$helper"; else sign "$helper"; fi
    done
else
    # Direct builds are not notarized; a plain signature keeps the identity
    # stable (with a certificate) and satisfies Apple silicon.
    sign() { codesign --force --timestamp=none --sign "$IDENTITY" "$@"; }
    for helper in "$APP/Contents/Helpers/"*; do sign "$helper"; done
fi
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
if [ "$MODE" = notarized ]; then
    codesign --force --timestamp --sign "$IDENTITY" "$DMG"
fi
if [ "$SKIP_NOTARIZE" != 1 ]; then
    notarize "$DMG"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
    spctl --assess --type open --context context:primary-signature --verbose=4 "$DMG"
fi
(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")

# The zip is what the one-line installer downloads (a stapled app in notarized mode).
ZIP="$DIST/Droplet-$DROPLET_VERSION.zip"
rm -f "$ZIP" "$ZIP.sha256" "$DIST/install.sh"
ditto -c -k --keepParent "$APP" "$ZIP"
(cd "$DIST" && shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256")
rm -rf "$DIST/site"
if [ -n "$DOWNLOAD_URL" ]; then
    python3 "$SRC_DIR/scripts/render_installer.py" --output "$DIST/install.sh" \
        --version "$DROPLET_VERSION" --zip-url "$FILES_URL/$(basename "$ZIP")" \
        --sha256 "$(cut -d' ' -f1 < "$ZIP.sha256")" --bundle-id "$DROPLET_BUNDLE_ID"
    # The whole website for upload: own hosting gets the zip and DMG in it too.
    # (Never empty: macOS's bash 3.2 treats an empty "${a[@]}" as unbound.)
    if [ -n "$GITHUB_REPO" ]; then HOSTING=(--host "GitHub Pages (GitHub, Inc.)"); else HOSTING=(--include-downloads); fi
    python3 "$SRC_DIR/scripts/build_site.py" --output "$DIST/site" "${HOSTING[@]}" \
        --version "$DROPLET_VERSION" --download-url "$DOWNLOAD_URL" --files-url "$FILES_URL" \
        --installer "$DIST/install.sh" --zip "$ZIP" --dmg "$DMG" \
        --notices "$APP/Contents/Resources/ThirdPartyNotices" --icon "$SRC_DIR/Resources/AppIcon.png" \
        --owner "$DROPLET_OWNER" --support "$SUPPORT" --price "${DROPLET_PRICE:-}" \
        --checkout-url "${DROPLET_CHECKOUT_URL:-}" --refund-days "${DROPLET_REFUND_DAYS:-14}" \
        --address "${DROPLET_ADDRESS:-}" --arch "$DROPLET_ARCH" --country "${DROPLET_COUNTRY:-}" \
        --launch-offer "${DROPLET_LAUNCH_OFFER:-0}" --launch-checkout-url "${DROPLET_LAUNCH_CHECKOUT_URL:-}"
fi

echo
echo "Release ready in $DIST:"
echo "  $(basename "$DMG")   $(cut -d' ' -f1 < "$DMG.sha256")"
echo "  $(basename "$ZIP")   $(cut -d' ' -f1 < "$ZIP.sha256")"
echo "  bundle id $DROPLET_BUNDLE_ID, version $DROPLET_VERSION ($DROPLET_BUILD), engine yt-dlp $ENGINE_VERSION, ${ARCHS[*]}"
if [ -n "$DOWNLOAD_URL" ]; then
    echo
    echo "Website for $DOWNLOAD_URL/ in $DIST/site. Publish it with: ./scripts/publish.sh"
    echo "Install command: curl -fsSL $DOWNLOAD_URL/install.sh | bash"
fi
if [ "$MODE" = direct ]; then
    echo
    echo "Direct build (no Developer ID): customers use the install command above, or open"
    echo "the DMG and allow it once in System Settings → Privacy & Security → Open Anyway."
fi
