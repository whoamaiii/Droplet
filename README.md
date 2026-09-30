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
  macOS Reduce Motion. Three successfully saved videos are available in the local trial; failed/cancelled attempts do not count. Paid activation is not configured.
- Powered by `yt-dlp` + `ffmpeg` (currently Homebrew). Site compatibility varies;
  a tested customer support matrix is still part of the release work.

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
development Homebrew update action and should not be used as a harmless UI test.

**Commercialization status:** the local three-download quota is implemented and tested, including process-crash recovery and instance ownership. It is not tamper-proof or verified against power loss. Paid activation remains unavailable; license provider configuration, bundled engine delivery and public signing remain in [the launch plan](docs/launch/LAUNCH-PLAN.md). See [30 September verification](docs/engineering/2026-09-30-takeover-verification.md) for current evidence and UI limitations.

## Start automatically at login

System Settings → General → Login Items → **+** → add
`~/Applications/Droplet.app`.

## Notes

- The very first download may trigger a one-time macOS prompt
  ("Droplet would like to access files in your Downloads folder").
  Grant access only if you want Droplet to save there. macOS may ask again
  after permission, signature or installation changes.
- If you move Homebrew, update the engine paths in `Sources/DropletKit/Infrastructure/DownloadEnvironment.swift`
  (`/opt/homebrew/bin/yt-dlp`) and rebuild.

## Keeping it working (important!)

Sites can change their download behavior. An engine update can help with some
failures; 403 or login errors can also mean the site does not permit downloading.
The current development updater still uses Homebrew; replacing it is tracked in
the launch plan.

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
kills the active download and cleans up only processes owned by Droplet,
boots out the launchd keep-alive agent (`com.quentinthiessen.droplet`) so
nothing resurrects it through that loaded job, and exits. Current process and
delegate checks are documented in the engineering reports; real login-service
migration and broader lifecycle checks remain tracked release tasks.

The launchd agent lives in `~/Library/LaunchAgents/com.quentinthiessen.droplet.plist`
(it auto-starts Droplet at login, with KeepAlive). Quitting boots it out until
the next login. To remove the auto-start permanently:

```bash
launchctl bootout gui/$(id -u)/com.quentinthiessen.droplet
rm ~/Library/LaunchAgents/com.quentinthiessen.droplet.plist
```

### Retries and time limits

**Try Again** starts a new attempt on the same video link. **Use new clipboard
link** reads a replacement link without starting it automatically. Browser-login
approval is never reused by an ordinary retry.

Droplet ignores external yt-dlp configuration/plugins and inherited proxy,
Python-path and certificate overrides. It uses controlled engine/FFmpeg paths.
Network requests have a 15-second socket timeout and at most two engine retries
per network/fragment/extractor operation, with a one-second retry delay. Only
recognized temporary network errors can use the additional public YouTube
attempt. Disk, permission, login, permanent-source and unknown errors stop.

The app checks for stalled work every ten seconds: two minutes without initial
progress, five minutes without new transfer progress, or thirty minutes without
a processing-stage change stops the job. Each attempt also has a six-hour limit.
A progressing transfer with unknown total size still counts as active. Timeouts
show an error and allow an explicit retry; they never count as a saved video.

The development Homebrew updater has a fifteen-minute limit; its asynchronous
version query has a five-second limit. Customer-ready bundled updates remain a
separate launch task.
