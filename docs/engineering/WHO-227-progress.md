# WHO-227 — in progress

28 September 2026. Do not move to another implementation issue or mark Done yet.

Existing good changes from WHO-224/226 are retained: multiple OnceCleanup records survive cancel->quit, cancelled validation workspaces are tracked, stale output/exit callbacks are token-scoped, watcher timers are cancelled, and updater shutdown flushes pending cleanup.

New change: ProcessIdentity captures PID plus kernel start seconds/microseconds. OwnedProcessSnapshot captures identities before graceful termination and rechecks them before delayed SIGKILL and sweep signals. Downloader cancellation/quit/sweep, updater timeout/quit and version-probe stop use this boundary. Missing identity means no signal. Tests inject process generations independently of PID.

Latest verification: **62 cases, 441 assertions, zero failures**. Simulated reused root and child IDs survive delayed cleanup, while the original child is stopped. Updater timeout followed by quit skips reused IDs too. Current kernel identity read is stable for the test process. A real process fixture creates a child while an unrelated real process runs; repeated cancel followed immediately by quit stops the owned root/child, preserves unrelated work and passes prior regressions. The fixture tolerates exited zombies as non-executing until the OS reaps them; it does not equate a still-executing child with completion.

This is start-time revalidation, not an atomic kernel compare-and-signal API. The check-to-kill interval and descendant discovery races still deserve critical review; do not claim proof for every theoretical process race. No global name-based kill was introduced.

Remaining work:
- Audit snapshot collection and immediate signals; strengthen startup isolation if needed. Current single-instance guard ranks NSWorkspace running apps and has a launchd-dormant path, but simultaneous visibility races are not proven safe. Consider an atomic per-bundle process lock while preserving compatibility with an older installed instance.
- Test actual duplicate starts without touching installed app, active popover close/reopen, merging cancellation, shutdown delegate path and sleep/wake behavior.
- Current applicationShouldTerminate calls quitApp, which exits directly and boots out the legacy KeepAlive agent. Preserve useful behavior; customer login-item migration remains WHO-239. Do not alter the user's installed launchd setup during QA.
- Verify actual UI/build, inspect process survivors, perform final critical review, then record complete evidence in Linear. System sleep/logout may require a user-coordinated real-machine check; don't pretend a unit test proves the physical event.

No install, commit, push or release. Installed app remains preserved. Goal stays active and WHO-227 stays In Progress.

## Further progress: atomic instance ownership

Added SingleInstanceLock backed by nonblocking flock. AppDelegate acquires it before constructing the menu-bar item and before dormant takeover. Existing NSWorkspace/rank check remains for compatibility with an older installed app that does not use the lock. Lock files are bundle-scoped under Application Support/Droplet/RuntimeLocks, owned by the current user, opened without following symlinks and with close-on-exec; multiply linked files are rejected. The stable lock inode is never unlinked on release. Exact known LaunchAgent label is now required for the dormant launchd path, rather than treating every nonempty XPC_SERVICE_NAME as that agent.

Verification: **65 cases, 451 assertions, zero failures**. Two actual competing child processes of the test executable ran the production lock implementation: exactly one acquired ownership, and a successor acquired it after the owner exited. Same-process reentry, separate contenders, release, symlink/hardlink rejection and preservation of the existing file contents also pass. This is real kernel-lock evidence, not yet proof that two complete GUI launches leave one icon.

Still required before Done: full native app startup/duplicate/dormant/popover checks, sleep/wake and system termination scenarios, merging shutdown coverage, final build/review. Distinguish lock failure from ordinary contention in the user-facing startup path (currently both refuse activation and only debug logging explains failure); audit startup-directory and ownership edges. No installed app or LaunchAgent was changed.

## Native app checks and remaining uncertainty

Startup-lock failure now presents a one-time explanatory native alert rather than silently treating a filesystem failure as an already-running instance. Preview-only window was enlarged and gained Open popover and System quit controls; both call real production actions. Neither control is compiled into a normal build. Last suite still **65 cases / 451 assertions / 0 failures**; optimized preview build/signature passed at `local.63BfpaVO`.

CUA launched `local.8XbXXj0F` as PID 9969. lsof confirmed it owned the stable preview lock inode. Opening another preview copy `local.2340Ufzg` through CUA timed out; authoritative process listing showed only the first app persisted. This is repeated-open evidence, not a confirmed simultaneous-GUI-launch trace. Clicking the app's Quit button removed PID 9969 and released the lock. The second copy then launched successfully as PID 10185 and owned the same inode; its Quit button also completed normally. Installed app PID 55748 remained running throughout.

A slow loopback server (8-second GET delay) and preview `local.63BfpaVO` exercised actual downloading. The fixture completed and the saved result survived attempted popover open/escape. CUA had a timeout after Escape; process PID 10719 was confirmed live before rebinding the same app (not restarting it). The saved result remained visible. The transfer completed before the active-popover test could be conclusively observed, so this acceptance check remains OPEN. Need a longer streaming fixture and a reliable observation of the actual popover, not just the preview window.

System quit preview action calls NSApp.terminate(nil), exercising applicationShouldTerminate -> existing quitApp cleanup. After clicking it, PID 10719 and its lock holder disappeared; installed app 55748 survived. This proves the native app termination delegate route, not physical macOS logout/shutdown. Slow fixture server PID 10468 was stopped. Retained fixture: `~/Library/Developer/Droplet/UIQA/cc6bd202-f11e-478f-8c14-21efc765306c`.

No assertion of actual sleep/wake or physical system shutdown. No installed LaunchAgent change. Remaining: active popover observation, merge shutdown regression, full GUI race/dormant coverage, sleep/wake handling/real check, final normal build and critical review.

## Active-popover and FFmpeg checks now verified

The loopback fixture now supports bounded per-chunk delay (512 bytes every two seconds), keeping the real download active long enough for native UI checks. Preview-only title counters come directly from NSPopoverDelegate.popoverDidShow/popoverDidClose, not the QA button itself. Normal builds exclude these counters and controls.

CUA evidence from `local.qkfLpzKl`: title reported menu opened 2 / closed 1 while the real transfer was at 29%; after the close action, opened 2 / closed 2 at 60%; after reopening, opened 3 / closed 2 at 80%. Progress was not reset. System quit then removed the app and owned engine; only the earlier verified complete output remained, and no staging directory remained. This resolves the earlier active-popover uncertainty. Fixture server 11262 and QA app 11616 were stopped; installed app 55748 remained alive. The preserved MP4 (11,859 bytes) passed full decode.

Latest suite: **66 cases, 459 assertions, zero failures**. The real child/bystander regression now uses two actual FFmpeg processes rather than sleep stand-ins: the owned FFmpeg stops and unrelated FFmpeg survives cancel->quit. Added explicit merge-stage shutdown test, including late successful exit not turning into Done. No fixture FFmpeg/server/app processes remained after checks.

A user-input question is pending for a short manually coordinated physical sleep/wake test. Changing physical sleep state can interrupt the user's other work; no sleep or logout has been triggered. Continue safe audit/build work while awaiting the answer, but do not mark physical behavior verified or advance to the next implementation issue. Remaining evidence gaps include physical sleep/wake/logout and fully observed simultaneous GUI-start/dormant takeover (kernel competition and repeated GUI opening already have separate evidence).

## Full duplicate/dormant app test — new unresolved observation

Preview-only buttons now use NSWorkspace.OpenConfiguration.createsNewApplicationInstance to launch the same verified preview bundle as another actual app process. The dormant button uses a preview-only command-line flag to select the real production dormant path; it does not register or alter a LaunchAgent. All controls/flags are compile-gated out of normal builds. Preview host sizing is now explicit so QA controls fit.

Build `local.37q8Znbr`: owner PID 13059 launched duplicate PID 13104 (NSWorkspace returned that PID in the visible window title). The duplicate exited and only owner 13059 held the lock, confirmed by ps/lsof. Dormant PID 13135 then launched and stayed alive without the lock while owner 13059 held it. After stopping only idle QA owner 13059 with SIGTERM, PID 13135 acquired the same lock inode.

**Unresolved:** CUA repeatedly returned noWindowsAvailable for the successor, including a fresh CUA session. A one-second `sample` of PID 13135 showed a normal idle NSApplication event loop, not a blocked main-thread function. Lock takeover is proven; usable GUI takeover is NOT. The successor was stopped with SIGTERM after diagnostics; no installed process/LaunchAgent was touched. Diagnostic sample remains `/tmp/droplet-13135-sample.txt`. Next useful action is preview-only lifecycle/state instrumentation to distinguish window creation/visibility from UI-tool PID selection, then repeat the actual dormant takeover test. Do not restart merely because an observation times out; the live process was explicitly inspected and stopped here.

Tests after these additions: **66 cases / 459 assertions / 0 failures**. Physical sleep/wake timing question remains unanswered. Continue within WHO-227; do not claim completion or advance to the next task.

## Diagnostic result and release-mode build

Preview `local.bNyr0hAk` owner 13682 launched dormant successor 13701. Before owner termination, the successor recorded `launched` and `dormant`, with no status item or window. After deliberately terminating only idle QA owner 13682, successor 13701 held the stable lock and recorded `activate-begin`, `status-item-created`, `preview-window-shown`, and `preview-window-settled`. All callbacks were on the main thread; the retained preview window reported visible and the app reported not hidden. Logs are under `~/Library/Developer/Droplet/UIQA/Lifecycle/13701.jsonl` (local QA data only, no URLs or credentials).

This narrows the uncertainty: the app does construct its UI after takeover. CUA still reports `noWindowsAvailable`, so an independently observed usable successor UI is not verified. Do not repeatedly rebuild the same behavior to substitute for this missing observation. Successor 13701 was explicitly stopped after diagnostics. Installed PID 55748 remained running and its executable SHA-256 remained `6f7da73a77227852337c839ebb41fc1c316f1464bc9bfda3f9fb204e1eb7248e`.

After instrumentation, the complete suite passed again: **66 cases / 459 assertions / 0 failures**. The normal optimized build passed plist and strict ad-hoc signature checks at `~/Library/Developer/Droplet/Builds/local.nT7ptQFc/Droplet.app`. Preview controls and lifecycle logging are excluded from that build. This is a local development artifact, not Developer ID signing or notarization.

Critical review confirmed delayed raw-PID cleanup paths use the identity snapshot in download cancellation, quit/sweep, updater cancellation and version-probe cancellation. Immediate graceful termination remains on the original Process object. Kernel-lock competition and preserved old-instance compatibility have separate tests. Physical sleep/wake/system-session behavior and independent successor UI interaction remain release acceptance gaps. User timing for the physical check is still pending; no sleep/logout, installed app replacement, LaunchAgent edit, commit, push or release occurred. WHO-227 stays In Progress and the next implementation issue has not started.
