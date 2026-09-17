# Audit implementation and acceptance checks

Baseline: the four uploaded files. The uploaded main.swift matches repository blob
`e4642ff85f9903b3c492d5ca8e323f96cf3ac671`. The running Mac installation was not
modified while preparing these changes. Implemented does not mean every behavior
has been verified on the user's Mac.

## Complete issue mapping

| Audit ID | Implemented change |
| --- | --- |
| H1 | Command identity and immutable request UUID guard both output and completion. Cancel invalidates first; retiring commands remain owned until cleanup. |
| H2 | No global process-name sweeps. Spawn creates an owned process group before exec; the unreaped leader reserves its PID through the final group signal. |
| H3 | Atomic lifetime file lock plus a versioned agent that restarts unsuccessful exits only. Duplicate clean exits cannot cause a respawn loop. |
| H4 | Compile/sign/lint before disruption; bootout before stopping; destination-filesystem staging; rollback; unique running-build verification. |
| M1 | Buffered complete byte lines, split UTF-8 handling, final EOF flush, FIFO callbacks and result-local final errors. |
| M2 | AppDelegate owns autoclose, cancels it on dismissal/open/state changes and checks session, generation and visibility. |
| M3 | Immutable URL, executable paths, output template and retry ladder captured at start. |
| M4 | Aggregate size-weighted or equal-stage stream progress, monotonic within an attempt, finalization reserve and approximate label. |
| M5 | Bundle ID and LaunchAgent label both use com.quentinthiessen.droplet; permission migration caveat documented. |
| M6 | Spawn/read/wait/reap/version/update off-main; asynchronous application termination; no launchctl calls inside Quit. |
| M7 | One idempotent shutdown path and one command registry; updater-only sessions are cleaned too. |
| L1 | Native architecture target; PATH, both Homebrew prefixes, user Python paths and explicit executable overrides. |
| L2 | waitid(WNOWAIT) observes actual exit rather than kill(pid,0) zombie polling; reap follows final signalling. |
| L3 | Precompiled, optional regular expressions with word boundaries and specific bot phrases. |
| L4 | --no-overwrites plus site/video ID filenames. Existing files may be skipped/reused instead of overwritten. |
| L5 | Strict H.264/AAC selection with clear unavailable-format errors; no arbitrary /best fallback. |
| L6 | Production smoke-download and smoke-update paths removed. Tests use temporary fake tools. |
| L7 | Try Again immediately starts the failed URL. |
| L8 | Synchronous @main under MainActor with no pointless await; build treats warnings as errors. |
| L9 | Machine-readable output replaces per-chunk regex parsing; remaining hint regexes are static and not force-unwrapped. |
| L10 | One documented/versioned autostart mechanism; installer creates and migrates its plist. |
| L11 | No unbounded /tmp logging; launchd output discarded; optional OSLog diagnostics. |
| L12 | Explicit accessibility labels on status icons and footer controls. |
| L13 | Resolved engine ownership checked against brew's actual formula prefix; other install methods receive a diagnosis. |

The final parser also supplies explicit JSON null defaults: yt-dlp skips JSON
conversion for missing fields. Without these defaults, a single-file format's
missing requested_formats could invalidate the entire metadata record.

## Automated coverage

Fourteen portable cases exercise the real Swift/C runner: chunk/UTF-8 boundaries,
bounded line memory, aggregate stream progress, hint boundaries, URL/argument
policy, final-error ordering, pipe-capacity output, TERM-resistant descendants,
timeouts, leader-first exit, unrelated-group safety, instance locking and absent
optional JSON fields. No network media downloads are performed.

The macOS-only manager suite checks cancel/restart isolation, captured retry URLs,
final error delivery, immediate Try Again and quit with both active and retiring
work. CI also builds/signs/verifies the app and typechecks both architectures.
Read the actual run result, not merely the workflow file, before calling these
macOS checks passed.

## Manual Mac acceptance checklist

1. Download a permitted two-stream video, verify non-resetting progress and open
   the resulting picture/audio in QuickTime. Test incompatible-only sources and
   an existing output file.
2. Repeatedly cancel and immediately restart. Change the clipboard during retries.
   Close/reopen the popover during downloads and within 1.9 seconds of success.
   Confirm no stale status updates or unexpected autoclose.
3. Run an unrelated ffmpeg job; cancel and quit Droplet and verify that job stays
   alive. Quit while updating the engine. Verify cancellation leaves no ordinary
   owned descendants.
4. Enable the new agent, attempt simultaneous launches and rebuild while running.
   Inject a compile failure and confirm the old app survives. Verify the new
   running build ID, normal Quit, crash restart, login and logout. Remove any
   duplicate legacy Login Item.
5. Test Homebrew, pip/pipx, missing tools and Intel path discovery. Confirm full
   diagnostics are available through the footer tooltip/accessibility.
6. Exercise installation/startup-failure rollback. Keep a source backup: disk
   failures, permission changes or SIGKILL between renames cannot be made fully
   transactional by a shell installer.

## Primary implementation references

- Apple spawn attributes: https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/posix_spawnattr_setflags.3.html
- Apple waitid/WNOWAIT definitions: https://github.com/apple-oss-distributions/xnu/blob/main/bsd/sys/wait.h
- Apple launchd.plist manual: https://github.com/apple-oss-distributions/launchd/blob/main/man/launchd.plist.5
- yt-dlp output templates: https://github.com/yt-dlp/yt-dlp#output-template
- Missing-field conversion behavior: https://github.com/yt-dlp/yt-dlp/blob/master/yt_dlp/YoutubeDL.py
