#!/bin/bash
# From a fresh checkout to an installable Droplet, in one command:
#
#   ./scripts/first-release.sh
#
#  1. checks this Mac has Apple's command line tools,
#  2. runs Droplet's checks (if Homebrew FFmpeg is there for the test videos),
#  3. creates the free "Droplet Signing" certificate once and backs it up,
#  4. pins the download engine (yt-dlp, FFmpeg, Deno) if not pinned yet,
#  5. asks a few questions and writes release.env (once),
#  6. builds the release into dist/ and offers to install it on this Mac.
#
# Safe to run again: finished steps are skipped. See docs/release/RELEASE.md.
set -euo pipefail
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$SRC_DIR"
CERT_NAME="Droplet Signing"
BACKUP_DIR="$HOME/Documents/Droplet signing certificate"

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
note() { printf '   %s\n' "$*"; }
fail() { printf '\nStopped: %s\n' "$*" >&2; exit 1; }
ask() { # ask "Question" default → $REPLY
    local answer
    if [ -n "${2:-}" ]; then read -r -p "   $1 [$2]: " answer; else read -r -p "   $1: " answer; fi
    REPLY="${answer:-${2:-}}"
}

[ "$(uname -s)" = Darwin ] || fail "run this on your Mac."

step "1/6 Developer tools"
if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install >/dev/null 2>&1 || true
    fail "a window to install Apple's Command Line Tools has opened. Install them, then run this script again."
fi
for tool in swift python3 codesign security; do
    command -v "$tool" >/dev/null || fail "$tool is missing; reinstall the Command Line Tools (xcode-select --install)."
done
note "OK ($(swift --version 2>/dev/null | head -1))"

step "2/6 Droplet's checks"
if [ -x /opt/homebrew/bin/ffmpeg ]; then
    ./scripts/test.sh </dev/null || fail "a check failed. Send the output above to whoever helps you with Droplet."
    python3 -m unittest discover -s Tests/Distribution </dev/null || fail "a distribution check failed (output above)."
else
    note "Skipped: the checks make test videos with Homebrew FFmpeg (/opt/homebrew/bin/ffmpeg)."
    note "The release build below still compiles everything."
fi

step "3/6 Free signing certificate \"$CERT_NAME\""
if security find-identity -p codesigning | grep -qF "\"$CERT_NAME\""; then
    note "Already in your keychain."
else
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $CERT_NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
    OPENSSL="${DROPLET_OPENSSL:-/usr/bin/openssl}"   # override only for the tests
    "$OPENSSL" req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes -config "$work/cert.cnf" \
        -keyout "$work/key.pem" -out "$work/cert.pem" 2>/dev/null || fail "could not create the certificate."
    password="$("$OPENSSL" rand -hex 16)"
    # security import only reads the classic PKCS#12 encryption, which
    # macOS's LibreSSL writes by default; OpenSSL 3 needs it requested.
    # (No arrays here: macOS bash 3.2 treats an empty "${a[@]}" as unbound.)
    if "$OPENSSL" version | grep -q LibreSSL; then
        "$OPENSSL" pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$CERT_NAME" \
            -out "$work/signing.p12" -passout "pass:$password" || fail "could not package the certificate."
    else
        "$OPENSSL" pkcs12 -export -legacy -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
            -inkey "$work/key.pem" -in "$work/cert.pem" -name "$CERT_NAME" \
            -out "$work/signing.p12" -passout "pass:$password" || fail "could not package the certificate."
    fi
    security import "$work/signing.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$password" -T /usr/bin/codesign \
        || fail "could not add the certificate to your login keychain."
    mkdir -p "$BACKUP_DIR"
    chmod 700 "$BACKUP_DIR"
    cp "$work/signing.p12" "$BACKUP_DIR/Droplet Signing.p12"
    printf 'Password for "Droplet Signing.p12": %s\n\nKeep this folder safe (for example in your password manager or an encrypted backup).\nEvery Droplet release must be signed with this same certificate.\nTo use it on another Mac: double-click the .p12 file and enter the password.\n' \
        "$password" > "$BACKUP_DIR/README - password.txt"
    chmod 600 "$BACKUP_DIR/"*
    security find-identity -p codesigning | grep -qF "\"$CERT_NAME\"" || fail "the certificate was imported but is not usable for code signing."
    note "Created and added to your login keychain."
    note "Backup: $BACKUP_DIR  ← keep this safe."
    note "When macOS asks whether codesign may use the \"$CERT_NAME\" key, enter your Mac password and click Always Allow."
fi

step "4/6 Download engine"
if [ -n "$(python3 scripts/fetch_engine.py --print-version)" ]; then
    note "Pinned: yt-dlp $(python3 scripts/fetch_engine.py --print-version)."
else
    python3 scripts/fetch_engine.py --pin --yt-dlp latest --deno latest --ffmpeg \
        || fail "pinning the engine failed (see above). If an FFmpeg address failed, see \"Pin the download engine\" in docs/release/RELEASE.md."
    note "Pinned yt-dlp $(python3 scripts/fetch_engine.py --print-version). Commit engine.lock.json to keep it:"
    note "  git add engine.lock.json && git commit -m 'Pin download engine'"
fi

step "5/6 Release settings (release.env)"
if [ -f release.env ]; then
    note "Using your existing release.env."
else
    note "Press Return to accept the suggestion in [brackets]."
    while :; do
        ask "Your website's domain, for example dropletapp.com"
        domain="$(printf '%s' "$REPLY" | tr '[:upper:]' '[:lower:]')"
        domain="${domain#https://}"; domain="${domain#http://}"; domain="${domain#www.}"; domain="${domain%%/*}"
        # In a variable: macOS's bash 3.2 cannot parse parentheses inside [[ =~ ]].
        domain_pattern='^[a-z0-9-]+(\.[a-z0-9-]+)+$'
        [[ "$domain" =~ $domain_pattern ]] && break
        note "That doesn't look like a domain; try again."
    done
    reversed="$(printf '%s' "$domain" | awk -F. '{for (i = NF; i > 0; i--) printf "%s%s", $i, (i > 1 ? "." : "")}')"
    ask "App identifier (never change it later)" "$reversed.droplet";            bundle_id="$REPLY"
    ask "Web folder for Droplet's files (install.sh goes here)" "https://$domain/droplet"; download="${REPLY%/}"
    ask "Support email" "support@$domain";                                      support="$REPLY"
    ask "Privacy policy page" "https://$domain/droplet/privacy";                privacy="$REPLY"
    ask "Your name or company (for the copyright line)" "";                     owner="$REPLY"
    note "Lemon Squeezy (leave empty if your store is not ready yet — you can add it to release.env later):"
    ask "  Store ID (numbers)" "";        store="$REPLY"
    ask "  Product ID (numbers)" "";      product="$REPLY"
    checkout=""
    if [ -n "$store" ]; then ask "  Checkout link (https://…)" ""; checkout="$REPLY"; fi
    for value in "$bundle_id" "$download" "$support" "$privacy" "$owner" "$store" "$product" "$checkout"; do
        [[ "$value" != *"'"* && "$value" != *\\* ]] || fail "please don't use quotes or backslashes in the answers."
    done
    {
        echo "# Written by scripts/first-release.sh — edit freely. See release.env.example."
        echo "DROPLET_BUNDLE_ID='$bundle_id'"
        echo "DROPLET_VERSION='1.0.0'"
        echo "DROPLET_BUILD='1'"
        echo "DROPLET_COPYRIGHT='© $(date +%Y) $owner'"
        echo "SIGNING_IDENTITY='$CERT_NAME'"
        echo "DROPLET_DOWNLOAD_URL='$download'"
        echo "DROPLET_WEBSITE_URL='https://$domain/droplet'"
        echo "DROPLET_SUPPORT='$support'"
        echo "DROPLET_PRIVACY_URL='$privacy'"
        echo "DROPLET_LS_STORE_ID='$store'"
        echo "DROPLET_LS_PRODUCT_ID='$product'"
        echo "DROPLET_LS_VARIANT_ID=''"
        echo "DROPLET_CHECKOUT_URL='$checkout'"
        if [ -z "$store" ]; then
            echo "# No store yet: the trial ends with no way to buy. Fill in the three"
            echo "# Lemon Squeezy values above and delete this line before publishing."
            echo "ALLOW_UNLICENSED='1'"
        fi
        echo "DROPLET_ARCH='universal'"
    } > release.env
    note "Wrote release.env (it stays on this Mac; git ignores it)."
fi
VALIDATE_ONLY=1 ./scripts/release.sh >/dev/null || fail "release.env needs a fix (message above). Edit it and run this again."

step "6/6 Building the release"
./scripts/release.sh
# shellcheck disable=SC1091
version="$(set -a; . ./release.env; echo "$DROPLET_VERSION")"
zip="dist/Droplet-$version.zip"
[ -f "$zip" ] || fail "the build did not produce $zip."
if grep -q "^ALLOW_UNLICENSED='1'" release.env; then
    note "This build has no store configured — fine for testing, not for selling."
fi

read -r -p $'\n   Install this build on this Mac now to try it? [Y/n] ' answer
if [[ "$answer" != [Nn]* ]]; then
    try="$(mktemp -d)"
    ditto -x -k "$zip" "$try"
    destination=/Applications
    [ -w "$destination" ] || { destination="$HOME/Applications"; mkdir -p "$destination"; }
    if pgrep -xq Droplet; then osascript -e 'quit app "Droplet"' >/dev/null 2>&1 || true; sleep 2; fi
    if [ -e "$destination/Droplet.app" ]; then mv "$destination/Droplet.app" "$try/previous-Droplet.app"; fi
    ditto "$try/Droplet.app" "$destination/Droplet.app"
    open "$destination/Droplet.app"
    note "Installed in $destination and opened — look for the drop in your menu bar."
fi

# shellcheck disable=SC1091
download_url="$(set -a; . ./release.env; echo "$DROPLET_DOWNLOAD_URL")"
printf '\n\033[1mDone.\033[0m Next:\n'
note "1. Upload everything in dist/ (zip first, install.sh last) to: $download_url/"
note "2. Put the install command and the text from docs/release/RELEASE.md on your download page."
note "3. Go through the customer checklist in docs/release/RELEASE.md (step 5)."
