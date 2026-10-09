# Droplet 💧

A tiny menu-bar app for macOS: click the droplet, press **Download**, and the
video URL sitting in your clipboard is saved as an **MP4** into
`~/Downloads` by default (or your chosen folder in Settings). macOS may ask for folder access; browser login is optional and
requires your explicit approval for that download.

- Lives in the menu bar (top right), no Dock icon.
- Animated water-droplet bubble with ripple + spring physics.
- Live progress %, cancel and explicit retry; saved-file actions remain visible until Done or a new link.
- Downloads continue in the background if you close the bubble
  (the menu-bar icon changes while a download runs).
- Settings (gear icon or Command-comma) lets you choose a save folder and view
  the version. A missing saved folder requires an explicit new choice.
- Getting started explains the menu-bar workflow; decorative movement respects
  macOS Reduce Motion.
- Three successfully saved videos are free; failed/cancelled attempts do not
  count. After that a one-time license (Lemon Squeezy) unlocks unlimited
  downloads. Settings has Buy, Activate, Check license and Deactivate this Mac.
- Powered by `yt-dlp`, FFmpeg and Deno, bundled inside the app in release
  builds (no Homebrew needed). The update button updates yt-dlp in place.
  Site compatibility varies.
- Optional **Open Droplet at login** in Settings (system login items).

## Installing (customers)

Droplet is sold and downloaded from its own website — not the Mac App Store,
and no paid Apple developer account is needed. Customers paste one line into
Terminal, which downloads the app, checks its SHA-256 fingerprint, installs it
into Applications and opens it, with no "unidentified developer" warning:

```bash
curl -fsSL https://yourdomain.com/droplet/install.sh | bash
```

Running the same line again updates Droplet. A DMG is also published for
people who prefer a normal download (they allow it once with System Settings →
Privacy & Security → Open Anyway).

**Publishing:** [docs/release/RELEASE.md](docs/release/RELEASE.md) covers the
free signing certificate, Lemon Squeezy, the download page text, engine
pinning, and the customer test checklist. `./scripts/release.sh` builds the
zip, `install.sh` and DMG into `dist/` for upload. A paid Developer ID can be
added later for notarization; nothing else changes.

## Development and local verification

- `Sources/DropletKit/` — download, update, infrastructure, and UI components
- `Sources/Droplet/main.swift` — app entry point
- `Tests/DropletKitTests/` — isolated executable checks
- `Package.swift` — Swift Package Manager configuration (macOS 14+, Swift 5 mode)
- `Info.plist` — bundle metadata

From the project directory:

```bash
./scripts/test.sh
python3 -m unittest discover -s Tests/Distribution -v
./build.sh
```

Development builds use Homebrew's `yt-dlp`, `ffmpeg` and (for YouTube) `deno`
from `/opt/homebrew/bin` or `/usr/local/bin`. To try the bundled-engine path,
assemble helpers with `python3 scripts/fetch_engine.py --output /tmp/helpers
--notices /tmp/notices` and build with `DROPLET_ENGINE_DIR=/tmp/helpers ./build.sh`.
The swift checks generate fixture videos with Homebrew FFmpeg.

The build writes a new **local, ad-hoc-signed** app beneath `~/Library/Developer/Droplet/Builds/`
and prints its path. It does not install over `~/Applications/Droplet.app`,
stop a running copy, change login items, or launch anything.

`./build.sh --preview` creates a separate app identity and opens a QA window
with the same view and an example URL when launched. The preview's Quit action does not unload the
installed app's LaunchAgent. This remains a development build, not a customer
release. The QA window is excluded from a normal build. It verifies the view;
menu-bar popover interactions still need their own release checks.

The checks run using Command Line Tools, without requiring XCTest/full Xcode.
See [architecture and verification boundaries](docs/engineering/ARCHITECTURE.md).

### Explicit local installation

For development, with Python 3 available, quit the target app using its own Quit
button, then install a completed build to an explicit path:

```bash
python3 scripts/install_app.py /absolute/path/to/built/Droplet.app \
  --destination "$HOME/Applications/Droplet.app"
```

The parent folder must already exist. The installer verifies the candidate and
staged copy, refuses an active target or loaded legacy KeepAlive job, then swaps
complete bundles atomically on the destination volume. It never kills a process,
loads/unloads login services, opens the app, or removes quarantine attributes.
If final verification fails, it swaps the old bundle back. A successful upgrade
prints the retained previous bundle and transaction record paths. Preserve those
files until the new version has been checked; they are the rollback material.
If rollback itself fails, the error identifies the recovery directory. Do not
delete it: inspect both signed bundles before attempting recovery.

This is a local developer tool, not a customer installer or automatic updater.
Public Developer ID signing, notarization, DMG delivery and customer updates are
separate release tasks. `DROPLET_BUILD_ROOT` optionally chooses a build output
directory; it never changes the installation destination.

### Development smoke controls

Only `--preview` builds compile the smoke flags and QA controls. Normal builds
ignore `--smoke-test` and `--smoke-update`. A preview `--smoke-test` requires an
explicit `--smoke-url=<url>` and optionally `--smoke-quit=<seconds>` (default 2.5).
It runs a real download, then invokes normal cleanup. Use permitted local fixture
media; no public video is downloaded by default. `--smoke-update` invokes the real
engine update action (network access; a no-op message on Homebrew development
engines) and should not be used as a harmless UI test.

**Commercialization status:** the local three-download quota is implemented and tested, including process-crash recovery and instance ownership. It is not tamper-proof or verified against power loss. License activation is implemented against Lemon Squeezy's License API and enabled when a release supplies store/product IDs (`release.env`); development builds show "Purchasing isn't set up in this build". See [the release guide](docs/release/RELEASE.md) and [the launch plan](docs/launch/LAUNCH-PLAN.md).

## Start automatically at login

Settings → **Open Droplet at login** registers Droplet as a system login item
(visible in System Settings → General → Login Items).

## Notes

- The very first download may trigger a one-time macOS prompt
  ("Droplet would like to access files in your Downloads folder").
  Grant access only if you want Droplet to save there. macOS may ask again
  after permission, signature or installation changes.
- Engine lookup order: `Droplet.app/Contents/Helpers` (release builds), a newer
  in-app update in `~/Library/Application Support/Droplet/Engine`, then Homebrew
  (`/opt/homebrew/bin`, `/usr/local/bin`) for development builds. See
  `Sources/DropletKit/Infrastructure/EngineLocator.swift`.

## Keeping it working (important!)

Sites can change their download behavior. An engine update can help with some
failures; 403 or login errors can also mean the site does not permit downloading.
The update button copies the current yt-dlp to a private folder, lets yt-dlp's
own updater fetch the latest stable release, checks the version and only then
switches to it. The signed app bundle is never modified, and a newer bundled
engine from an app update takes precedence. Development builds that use
Homebrew are updated with `brew upgrade yt-dlp`.

Ordinary downloads never discover browser profiles or import browser cookies.
They do not require Full Disk Access. User yt-dlp configuration, plugins and netrc
credentials are excluded from the app's download command.

After a failed download, **Use browser login…** offers an optional explanation
and a choice of one browser and profile. **Use login once** approves only the
shown URL for that download. Blank profile means the browser's default profile;
Safari supports the default profile only. Cancel closes the prompt without
starting a download. Cancel during downloading stops the job; the next ordinary
download does not use browser login. No browser choice is saved.

The engine reads cookies locally and uses matching cookies for the requested
site. macOS or the browser may deny access; use a public link if access is denied.
Droplet does not require changing macOS security settings for ordinary use.
Cookies, video URLs and browsing history are not sent to a license provider,
support service or telemetry by the current app. The future license adapter must
preserve this separation. Authentication never guarantees a site allows downloads.

## Quitting

The **"Quit Droplet — stop everything"** button does a *complete* shutdown:
kills the active download and cleans up only processes owned by Droplet, and
exits. If the old development KeepAlive agent
(`~/Library/LaunchAgents/com.quentinthiessen.droplet.plist`) exists, quitting
also boots it out so it cannot resurrect the app. Customer installs never have
that agent; they use the Open at login setting. To remove the old agent permanently:

```bash
launchctl bootout gui/$(id -u)/com.quentinthiessen.droplet
rm ~/Library/LaunchAgents/com.quentinthiessen.droplet.plist
```

### Retries and time limits

**Try Again** starts a new attempt on the same video link. **Use new clipboard
link** reads a replacement link without starting it automatically. Browser-login
approval is never reused by an ordinary retry.

Droplet ignores external yt-dlp configuration/plugins and inherited proxy,
Python-path and certificate overrides. It uses controlled engine/FFmpeg paths
and yt-dlp's own per-site request headers.
Network requests have a 15-second socket timeout and at most two engine retries
per network/fragment/extractor operation, with a one-second retry delay. Only
recognized temporary network errors can use the additional public YouTube
attempt. Disk, permission, login, permanent-source and unknown errors stop.

The app checks for stalled work every ten seconds: two minutes without initial
progress, five minutes without new transfer progress, or thirty minutes without
a processing-stage change stops the job. Each attempt also has a six-hour limit.
A progressing transfer with unknown total size still counts as active. Timeouts
show an error and allow an explicit retry; they never count as a saved video.

The engine update has a fifteen-minute limit; its asynchronous version query
has a five-second limit.
