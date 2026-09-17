# Droplet 💧

A tiny menu-bar app for macOS: click the droplet, press **Download**, and the
video URL sitting in your clipboard is saved as an **MP4** into
`~/Downloads` — no dialogs, no approvals.

- Lives in the menu bar (top right), no Dock icon.
- Animated water-droplet bubble with ripple + spring physics.
- Live progress %, cancel, retry, auto-close on success.
- Downloads continue in the background if you close the bubble
  (the menu-bar icon changes while a download runs).
- Powered by `yt-dlp` + `ffmpeg` (Homebrew) — supports YouTube and 1000+ sites.

## Files

- `main.swift` — the whole app (Swift/SwiftUI, single file)
- `Info.plist` — bundle metadata
- `build.sh` — rebuild & relaunch script

## Build

```bash
chmod +x ~/Droplet/build.sh
~/Droplet/build.sh
```

The app installs to `~/Applications/Droplet.app`.

## Start automatically at login

System Settings → General → Login Items → **+** → add
`~/Applications/Droplet.app`.

## Notes

- The very first download may trigger a one-time macOS prompt
  ("Droplet would like to access files in your Downloads folder").
  Click **Allow** once — it is never asked again.
- If you move Homebrew, update the yt-dlp path in `main.swift`
  (`/opt/homebrew/bin/yt-dlp`) and rebuild.

## Keeping it working (important!)

YouTube and other sites change their internals constantly. A **stale download
engine is the #1 cause of `HTTP Error 403: Forbidden`** — if downloads suddenly
start failing, that's almost always it.

- Quick fix: click the **↻ button** in the bubble's footer — Droplet updates
  yt-dlp in the background and shows the new version.
- Terminal equivalent: `brew upgrade yt-dlp`
- Droplet also retries automatically before giving up: browser-like headers,
  alternate YouTube clients, and cookies from browsers you actually have
  installed (Safari/Chrome/Brave/Edge/Firefox).

Safari cookie fallback requires granting Droplet **Full Disk Access**
(System Settings → Privacy & Security → Full Disk Access).

## Quitting

The **"Quit Droplet — stop everything"** button does a *complete* shutdown:
kills the active download, sweeps every yt-dlp/ffmpeg process on the Mac,
boots out the launchd keep-alive agent (`com.quentinthiessen.droplet`) so
nothing resurrects the app, and exits. Verified: no respawn for 12+ s.

The launchd agent lives in `~/Library/LaunchAgents/com.quentinthiessen.droplet.plist`
(it auto-starts Droplet at login, with KeepAlive). Quitting boots it out until
the next login. To remove the auto-start permanently:

```bash
launchctl bootout gui/$(id -u)/com.quentinthiessen.droplet
rm ~/Library/LaunchAgents/com.quentinthiessen.droplet.plist
```
