# WHO-226 — isolated, bounded engine operation

Verified 28 September 2026. Supersedes the incremental progress notes; this is not a sale-ready release certification.

## Acceptance mapping

1. **Configuration isolation:** downloader ignores external config and plugin directories. Its environment is constructed from controlled HOME, temporary directory, engine/FFmpeg paths and locale/Python isolation keys. No inherited proxy, loader, Python-path, certificate or config overrides are passed. Browser access still requires WHO-225 consent. EngineProcessEnvironment tests check the exact key set; an actual app download with this environment succeeded.
2. **Failure/retry policy:** DownloadFailure distinguishes temporary network errors, source failures, authentication, filesystem permissions/disk and missing engine launch errors. Unknown failures stop. Only recognized temporary network failures advance the public attempt list (at most two attempts); consented browser runs remain single-attempt. Engine network/fragment/extractor retries are two with one-second sleep and a 15-second socket timeout. Failed output is never success. Known errors receive concise actionable text; unknown diagnostics are bounded to 400 characters. Real installed engine parser verified the timeout/retry options.
3. **URL safety:** DownloadURLPolicy validates HTTP/S scheme, host labels, IPv6 via inet_pton, port, percent escapes, controls, whitespace, length and absence of embedded credentials. Domain membership uses exact host/subdomain boundaries. The complete URL remains a separate Process argument, never shell text. Tests include lookalike hosts, credentials, malformed URLs and shell punctuation.
4. **Explicit retry versus new input:** Try Again starts the captured original URL, without carrying browser approval forward. Reopening a failed session preserves the original failure and retry choice. Use new clipboard link refreshes without starting. Retry is disabled without a failed job's original URL. Unit tests and native UI checks cover these behaviors.
5. **Bounded IO without main-thread wait:** engine socket and retry flags plus cancellable per-attempt watchdog; asynchronous EngineVersionProbe waits for ordered EOF+exit with output bounds and five-second deadline. No synchronous readDataToEndOfFile/waitUntilExit remains in the updater. Development update deadline is 15 minutes, with owned graceful termination and hard-kill fallback. Shutdown flushes pending cleanup. Process identity/generation protects replacement jobs and stale dismiss/deadline/exit callbacks.

## Final evidence

`./scripts/test.sh`: **58 cases, 426 assertions, 0 failures**. Includes existing media/process regressions and new failure classification, environment, URL, retry, watchdog, updater-success/version, updater timeout/shutdown and stale callback checks.

Real executable fixtures that sleep verify main-queue responsiveness, timeout transition and actual OS process termination for both version query and download manager. The download fixture also verifies staging cleanup. Tests accelerate the clock; normal deadlines are checked using virtual time. No six-hour real wait or actual Homebrew upgrade was performed.

Native preview `local.HZDLvLrx`: actual Download against a self-generated loopback MP4 succeeded using the new environment and arguments; the UI displayed Saved to Downloads. Output:
`/Users/quentinthiessen/Library/Developer/Droplet/UIQA/30067499-37cc-4101-b63a-5d76855a9b5c/Downloads/Droplet-QA [84c468c79207].mp4`
11,859 bytes, full FFmpeg decode passed. The server was stopped, then actual Try Again produced a connection-refused failure on the same URL. This caught an overly long raw error message; it was replaced with concise classified help.

Native preview `local.JJQQ36GB`: actual unreachable-loopback download displayed the new short network error; screenshot confirmed room for all actions. Use new clipboard link returned to input without starting. Synthetic failed-state control after clearing the original job showed Try Again disabled. The final later source change preserves a failed session on reopening and is covered by the final suite and normal build.

QA app PIDs 6547 and 7357 and fixture server 6297 were stopped. Installed app executable SHA256 remained `6f7da73a77227852337c839ebb41fc1c316f1464bc9bfda3f9fb204e1eb7248e`. No install, commit, push, account operation or release performed.

## Critical review

Reviewed every start/consent/retry path, process environment, URL validation, timer cancellation, owned cleanup, version callback ordering and updater shutdown/restart. Corrected malformed-percent/IPv6 acceptance, stale updater exits, dismiss timers, retry losing its URL on popover reopen, and verbose real engine errors before closure. README records actual limits and remaining development-updater status.

## Practical limits

Diagnostic classification is conservative text matching: unknown errors are surfaced rather than guessed transient. Watchdog checks are every ten seconds; live large-video/slow-disk coverage belongs to WHO-244/245. The engine and updater still use developer Homebrew paths: bundled delivery and customer update integrity remain WHO-222/238. No clean-Mac, public signing, real private-browser access, payment or live updater installation is claimed. General contrast/accessibility and source matrix remain WHO-229/245.

Normal optimized build and strict ad-hoc signature verification passed: `/Users/quentinthiessen/Library/Developer/Droplet/Builds/local.OmYWER4r/Droplet.app`.
