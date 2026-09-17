# Droplet 💧

A macOS 14+ menu-bar app. Copy a video URL, open the droplet and press **Download**.
Downloads continue when the popover closes. The original animated interface is retained.

## Build and install

Install Xcode Command Line Tools and the download tools first. Homebrew users:

```sh
brew install yt-dlp ffmpeg
bash Tests/run.sh
bash build.sh
```

The build targets the current Mac (Apple Silicon or Intel) and installs to
`~/Applications/Droplet.app`. Compilation, plist validation and signing complete
before the old app is stopped. The installer unloads its LaunchAgent before
replacement, keeps a rollback copy, and checks a unique build ID and PID before
reporting that the new build is running.

```sh
bash build.sh --check       # compile/sign/check only; no install or launch
bash build.sh --no-launch   # install without starting
bash build.sh --login       # install/update the versioned login agent
bash build.sh --no-login    # remove that agent and launch normally
```

**First upgrade from version 1:** cancel any active download and let an engine
update finish before rebuilding. The installer refuses to interrupt a legacy
instance with child processes. **Do not use the legacy "stop everything" Quit
button:** it kills unrelated ffmpeg/yt-dlp processes. The replacement does not.

After a forcibly killed install, confirm no installer is running before removing
an empty `~/Applications/.droplet-install-lock` directory. Never delete the runtime
`instance.lock` file. Filesystem failures or SIGKILL in the middle of replacement
cannot be made perfectly transactional by a shell script; retain your source.

## One login mechanism

Ordinary rebuilds preserve whether the agent was installed. `--login` renders
`com.quentinthiessen.droplet.plist` with your actual executable path and installs it
in `~/Library/LaunchAgents`. RunAtLoad starts it at login; the
`KeepAlive.SuccessfulExit = false` policy restarts unsuccessful exits, not normal
Quit or duplicate instances' clean exits. The lifetime file lock makes concurrent
launches first-winner-only.

Do not also add Droplet as a separate Login Item. Remove an existing duplicate
entry in System Settings → General → Login Items. Normal Quit leaves the agent
installed for the next login. To restart immediately after Quit, open the app.
A manually opened instance is not supervised for crash recovery by launchd.
`--no-launch` installs the agent when requested but leaves it unloaded until login.

## Download behavior

The request captures its URL and executable paths. Changing the clipboard cannot
redirect retries, and **Try Again** immediately retries the same failed URL.

Compatible MP4 mode selects **H.264 video and AAC audio**. It can select lower
resolution than a site's VP9/AV1 formats. If no compatible format exists, it reports
that limitation; it does not silently transcode or pretend a container change fixes
incompatible codecs. Filenames include site and video ID. `--no-overwrites` protects
existing files: an already saved video can be skipped/reused, not saved as a second
copy. Partial files may resume; Droplet never deletes your downloads.

Progress is explicitly approximate, aggregated across selected streams using size
estimates when available and equal stage weights otherwise. The final 5% is
reserved for merge/postprocessing. Only successful completion reaches 100%.

External yt-dlp config is ignored so it cannot override the output, progress,
overwrite or format policy. Browser-cookie retries are limited to existing browser
profiles. macOS permissions may be needed. Retries cannot guarantee access to
unavailable, restricted, or blocked videos; an update is not a universal 403 fix.

## Tool discovery and updates

Discovery checks explicit absolute-path overrides, inherited PATH, both Homebrew
locations, `~/.local/bin`, and user Python bin directories. Optional overrides are
`DROPLET_YTDLP`, `DROPLET_FFMPEG`, and `DROPLET_BREW`. Set these in the launch
environment for Finder/launchd; Terminal-only exports do not update a running GUI.

The update button verifies that the resolved yt-dlp executable belongs to the
selected Homebrew's actual `brew --prefix yt-dlp` directory before upgrading it.
pip, pipx, standalone, mismatched Homebrew and missing installations get an
explanation. Hover the footer message for the full diagnostic. Updates and version
queries run off-main; an active download cannot overlap an engine update.

Bundle ID and agent label are `com.quentinthiessen.droplet`. This changes the old
`local.quentinthiessen.droplet` identity, so macOS permissions may need granting
again. TCC grants are not automatically migrated.

## Process safety and limits

A fresh process group is created during POSIX spawn, before execution. Cancel/Quit
signals only owned groups. The leader's PID remains reserved, unreaped, until the
last group signal; escalation cannot target a recycled PID. Cancelled commands
remain registered until cleanup finishes. Quit also cancels updater/version work.
There are no global pkill sweeps and no subprocess waits on the UI thread.

Output is byte-buffered into complete lines, including split UTF-8 and a final
unterminated error. Completion follows output delivery. Line and diagnostic-tail
buffers are bounded. Autoclose is cancelled on dismissal and checks both popover
session and download generation.

Process groups are not a sandbox: a program deliberately calling setsid/leaving
the group can escape. SIGKILL of Droplet itself cannot execute cleanup. Untracked
orphans from old versions are not swept. The LaunchAgent sends stdout/stderr to
`/dev/null`, not a growing `/tmp` file. Optional `DROPLET_DEBUG=1` uses OSLog with
private dynamic messages. Old log files are not deleted automatically. Production
has no command-line flags that start real smoke downloads or updates.

## Source and validation

`main.swift` holds the manager, interface and lifecycle. `DownloadCore.swift` holds
arguments, parsing and discovery. `ProcessRuntime.swift` and `ProcessSupport.c/.h`
implement subprocess ownership.

`Tests/run.sh` runs 14 portable Foundation/POSIX tests and, on macOS, four manager
integration tests using temporary fake tools. CI builds and verifies the signed
app without installing it, and typechecks arm64 and x86_64 with warnings as errors.
A workflow's presence is not evidence that it passed: inspect the commit's run.
Real-site downloads, QuickTime playback, the UI, login/logout and rollback require
manual Mac acceptance testing. See `AUDIT_FIXES.md`.
