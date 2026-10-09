#!/bin/bash
# Puts the release in dist/ online so customers can install it:
#
#   ./scripts/publish.sh               publish (asks before anything goes public)
#   ./scripts/publish.sh --check       only check what is online now
#   ./scripts/publish.sh --trial-only  also allow a build without a Lemon Squeezy
#                                      store (a first test of the website, or while
#                                      the store waits for approval)
#   --yes                              answer yes to the questions (first-release.sh)
#
# Free GitHub hosting (DROPLET_GITHUB_REPO in release.env): uploads the zip and
# DMG to a GitHub release, then the website with install.sh to GitHub Pages, in
# that order, and waits until the install command works. It needs GitHub's
# command-line tool once:  brew install gh && gh auth login
# Your own website: lists what to upload; run it with --check afterwards.
set -euo pipefail
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${DROPLET_RELEASE_ENV:-$SRC_DIR/release.env}"
DIST="${DROPLET_DIST_DIR:-$SRC_DIR/dist}"
CHECK_ONLY=0
TRIAL_ONLY=0
ASSUME_YES=0
for arg in "$@"; do
    case "$arg" in
        --check) CHECK_ONLY=1 ;;
        --trial-only) TRIAL_ONLY=1 ;;
        --yes) ASSUME_YES=1 ;;
        *) echo "usage: publish.sh [--check] [--trial-only] [--yes]" >&2; exit 2 ;;
    esac
done

say() { printf '==> %s\n' "$*"; }
fail() { printf 'publish: %s\n' "$*" >&2; exit 1; }
confirm() {
    [ "$ASSUME_YES" = 1 ] && return 0
    local answer=""
    read -r -p "$1 [y/N] " answer || true
    [[ "$answer" == [Yy]* ]]
}

[ -f "$CONFIG" ] || fail "missing $CONFIG. Run ./scripts/first-release.sh first."
set -a
# shellcheck disable=SC1090
. "$CONFIG"
set +a
VERSION="${DROPLET_VERSION:-}"
DOWNLOAD_URL="${DROPLET_DOWNLOAD_URL:-}"
DOWNLOAD_URL="${DOWNLOAD_URL%/}"
[ -n "$DOWNLOAD_URL" ] || fail "DROPLET_DOWNLOAD_URL is not set in release.env: there is no website to publish to."
ZIP="$DIST/Droplet-$VERSION.zip"
DMG="$DIST/Droplet-$VERSION.dmg"
SITE="$DIST/site"
for file in "$ZIP" "$ZIP.sha256" "$DMG" "$DMG.sha256" "$SITE/install.sh" "$SITE/index.html"; do
    [ -f "$file" ] || fail "$file is missing. Build the release first: ./scripts/release.sh"
done
ZIP_SHA="$(cut -d' ' -f1 < "$ZIP.sha256")"
[ "$(shasum -a 256 "$ZIP" | cut -d' ' -f1)" = "$ZIP_SHA" ] || fail "$(basename "$ZIP") changed after it was built. Build again."
grep -qx "SHA256=\"$ZIP_SHA\"" "$SITE/install.sh" || fail "dist/site/install.sh belongs to another build. Build again."

# Read what the build really contains, so a stale dist/ cannot be published.
built() {
    python3 - "$ZIP" "$1" <<'PY'
import plistlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as bundle:
    info = plistlib.loads(bundle.read("Droplet.app/Contents/Info.plist"))
print(info.get(sys.argv[2], ""))
PY
}
[ "$(built CFBundleIdentifier)" = "${DROPLET_BUNDLE_ID:-}" ] && [ "$(built CFBundleShortVersionString)" = "$VERSION" ] \
    || fail "dist/ holds a different build than release.env describes. Build again: ./scripts/release.sh"
STORE="$(built DropletLicenseStoreID)"
if [ -z "$STORE" ] && [ "$CHECK_ONLY" = 0 ] && [ "$TRIAL_ONLY" = 0 ]; then
    fail "this build has no Lemon Squeezy store, so after the 3 free downloads nobody could buy a license.
Add the store to release.env and build again (docs/release/RELEASE.md), or publish it on purpose as a
trial-only version: ./scripts/publish.sh --trial-only"
fi

GITHUB_REPO="${DROPLET_GITHUB_REPO:-}"
FILES_URL="$DOWNLOAD_URL"
FOLDER=""
if [ -n "$GITHUB_REPO" ]; then
    FILES_URL="https://github.com/$GITHUB_REPO/releases/download/v$VERSION"
    FOLDER="$("$SRC_DIR/scripts/github_pages.sh" folder "$GITHUB_REPO" "$DOWNLOAD_URL")" \
        || fail "DROPLET_DOWNLOAD_URL ($DOWNLOAD_URL) is not on the GitHub Pages site of $GITHUB_REPO"
    case "/$FOLDER" in */.*) fail "the website folder may not start with a dot: $FOLDER" ;; esac
fi
grep -qxF "ZIP_URL=\"$FILES_URL/$(basename "$ZIP")\"" "$SITE/install.sh" \
    || fail "dist/ was built for other download settings than release.env has now. Build again: ./scripts/release.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/droplet-publish.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# Waits up to $1 seconds until the website serves this build's install.sh,
# then downloads the zip the way customers do and checks its fingerprint.
check_online() {
    local deadline=$((SECONDS + $1))
    say "Checking $DOWNLOAD_URL/install.sh ..."
    until curl -fsSL "$DOWNLOAD_URL/install.sh?check=$RANDOM" -o "$WORK/install.sh" 2>/dev/null \
            && cmp -s "$WORK/install.sh" "$SITE/install.sh"; do
        [ "$SECONDS" -lt "$deadline" ] \
            || fail "$DOWNLOAD_URL/install.sh does not serve this build yet. Upload it (or wait a few minutes), then run: ./scripts/publish.sh --check"
        sleep 10
    done
    curl -fsSL "$DOWNLOAD_URL/?check=$RANDOM" -o "$WORK/index.html" 2>/dev/null \
        || fail "the download page does not load: $DOWNLOAD_URL/"
    say "Downloading $(basename "$ZIP") the way customers do..."
    curl -fsSL "$FILES_URL/$(basename "$ZIP")" -o "$WORK/Droplet.zip" \
        || fail "could not download $FILES_URL/$(basename "$ZIP")"
    [ "$(shasum -a 256 "$WORK/Droplet.zip" | cut -d' ' -f1)" = "$ZIP_SHA" ] \
        || fail "the zip online is not this build. Upload $(basename "$ZIP") again."
    echo
    say "Droplet $VERSION is online."
    echo "    Download page:   $DOWNLOAD_URL/"
    echo "    Install command: curl -fsSL $DOWNLOAD_URL/install.sh | bash"
}

if [ "$CHECK_ONLY" = 1 ]; then
    check_online 60
    exit 0
fi

if [ -z "$GITHUB_REPO" ]; then
    echo "Upload everything inside this folder to $DOWNLOAD_URL/ (your web host's file manager or FTP):"
    echo "    $SITE"
    echo "Upload $(basename "$ZIP") and $(basename "$DMG") first and install.sh last, so the install"
    echo "command never points to a file that is not there yet. Then check it with:"
    echo "    ./scripts/publish.sh --check"
    exit 0
fi

# ---------------------------------------------------------------- GitHub
command -v gh >/dev/null || fail "GitHub's command-line tool is needed. Install it with:  brew install gh
then log in with:  gh auth login"
gh auth status >/dev/null 2>&1 || fail "log in to GitHub first:  gh auth login"
LOGIN="$(gh api user --jq .login)"
TAG="v$VERSION"
echo "Droplet $VERSION goes online for everyone:"
echo "    website:   $DOWNLOAD_URL/"
echo "    downloads: https://github.com/$GITHUB_REPO/releases/tag/$TAG"
[ -n "$STORE" ] || echo "    (trial only: this build has no store yet)"
confirm "Publish now?" || fail "nothing was published."

if ! gh repo view "$GITHUB_REPO" >/dev/null 2>&1; then
    if [ "$(printf '%s' "${GITHUB_REPO%%/*}" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$LOGIN" | tr '[:upper:]' '[:lower:]')" ]; then
        fail "$GITHUB_REPO does not exist, and you are logged in to GitHub as $LOGIN. Correct DROPLET_GITHUB_REPO
and DROPLET_DOWNLOAD_URL in release.env and build again, or log in as ${GITHUB_REPO%%/*}: gh auth login"
    fi
    say "Creating the public repository $GITHUB_REPO..."
    gh repo create "$GITHUB_REPO" --public --description "Droplet for Mac: website and downloads" >/dev/null
fi
[ "$(gh repo view "$GITHUB_REPO" --json visibility --jq .visibility)" = PUBLIC ] \
    || fail "$GITHUB_REPO must be public: GitHub serves free websites and downloads only from public repositories."

# git uses gh's login for this push only; your git settings are not changed.
git_gh() { git -c credential.helper= -c 'credential.helper=!gh auth git-credential' "$@"; }
USER_ID="$(gh api user --jq .id)"
commit() { git -c user.name="$LOGIN" -c user.email="$USER_ID+$LOGIN@users.noreply.github.com" commit --quiet -m "$1"; }
say "Getting the website repository..."
git_gh clone --quiet "${DROPLET_GITHUB_GIT_URL:-https://github.com/$GITHUB_REPO.git}" "$WORK/repo"
cd "$WORK/repo"
if ! git rev-parse --verify --quiet HEAD >/dev/null; then
    # A new, empty repository needs a first commit before it can have releases.
    git symbolic-ref HEAD refs/heads/main
    printf '# Droplet\n\nThe website and downloads for Droplet: %s/\n' "$DOWNLOAD_URL" > README.md
    : > .nojekyll   # plain files: GitHub Pages publishes them as they are
    git add README.md .nojekyll
    if [ -n "$FOLDER" ]; then   # the site's front page leads to Droplet
        printf '<!doctype html>\n<meta charset="utf-8">\n<title>Droplet</title>\n<meta http-equiv="refresh" content="0; url=%s/">\n<a href="%s/">Droplet</a>\n' \
            "$FOLDER" "$FOLDER" > index.html
        git add index.html
    fi
    commit "Start the Droplet website"
    git_gh push --quiet origin main
fi
BRANCH="$(git rev-parse --abbrev-ref HEAD)"
# An existing GitHub Pages site may publish another branch or its docs/ folder.
PAGES_ON=0
PAGES_ROOT="$WORK/repo"
if pages="$(gh api "repos/$GITHUB_REPO/pages" --jq '(.source.branch // "") + " " + (.source.path // "/")' 2>/dev/null)"; then
    PAGES_ON=1
    pages_branch="${pages%% *}"
    if [ -n "$pages_branch" ] && [ "$pages_branch" != "$BRANCH" ]; then
        git_gh fetch --quiet origin "$pages_branch"
        git checkout --quiet -B "$pages_branch" FETCH_HEAD
        BRANCH="$pages_branch"
    fi
    if [ "${pages#* }" = "/docs" ]; then PAGES_ROOT="$WORK/repo/docs"; fi
fi

# The zip and DMG first, install.sh last: the install command never points to
# a file that is not online yet.
if gh release view "$TAG" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
    confirm "Droplet $VERSION is already on GitHub. Replace its files with this build?" \
        || fail "nothing changed. For a new version, raise DROPLET_VERSION and DROPLET_BUILD in release.env and build again."
    say "Replacing the files of Droplet $VERSION..."
    gh release upload "$TAG" "$ZIP" "$ZIP.sha256" "$DMG" "$DMG.sha256" --repo "$GITHUB_REPO" --clobber
else
    say "Uploading Droplet $VERSION (this can take a few minutes)..."
    gh release create "$TAG" "$ZIP" "$ZIP.sha256" "$DMG" "$DMG.sha256" --repo "$GITHUB_REPO" \
        --target "$BRANCH" --title "Droplet $VERSION" \
        --notes "Install or update Droplet: curl -fsSL $DOWNLOAD_URL/install.sh | bash" >/dev/null
fi

say "Updating the website..."
TARGET="$PAGES_ROOT"
if [ -n "$FOLDER" ]; then
    TARGET="$PAGES_ROOT/$FOLDER"
    rm -rf "$TARGET"   # Droplet's folder only; the rest of the repository stays as it is
fi
mkdir -p "$TARGET"
cp -R "$SITE/." "$TARGET/"
git add -A
if git diff --cached --quiet; then
    say "The website was already up to date."
else
    commit "Droplet $VERSION website"
    git_gh push --quiet origin "$BRANCH"
fi
if [ "$PAGES_ON" = 0 ] && ! gh api "repos/$GITHUB_REPO/pages" >/dev/null 2>&1; then
    say "Turning on GitHub Pages..."
    gh api -X POST "repos/$GITHUB_REPO/pages" -f "source[branch]=$BRANCH" -f "source[path]=/" >/dev/null \
        || fail "could not turn on GitHub Pages. Open https://github.com/$GITHUB_REPO/settings/pages, choose
\"Deploy from a branch\", $BRANCH and / (root), click Save, then run: ./scripts/publish.sh --check"
fi
cd "$SRC_DIR"
say "Waiting for GitHub Pages to publish the website (usually 1 to 3 minutes)..."
check_online 900
