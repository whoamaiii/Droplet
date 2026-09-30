# Completed: see [final verification](WHO-226-verification.md)

# WHO-226 — in progress

28 September 2026. Do not mark Done or begin another implementation issue yet.

Implemented so far:
- Shared DownloadURLPolicy validates all process entry points and browser consent; HTTP/S only, no embedded credentials, bounded size, host/port validation. Domain membership uses exact/subdomain boundaries. Separate Process arguments preserve URL special characters without shell evaluation.
- Try Again starts a new cookie-free attempt of the captured original URL. A separate Use new clipboard link action refreshes the input without automatically starting it. Prior browser consent is not reused.
- Conservative diagnostic classification stops disk, permissions, authentication, source and unknown failures. Only recognized temporary network failures may proceed to the existing bounded attempt list. Real netrc default was already verified in WHO-225.
- EngineProcessEnvironment constructs an explicit environment with controlled HOME/temp/PATH and UTF-8/Python isolation. It does not inherit proxy, Python path, loader, certificate or config overrides. Required engine/FFmpeg directories remain available.

Current test evidence: `./scripts/test.sh` passed 47 cases, 355 assertions, 0 failures. New cases cover URL/host boundaries, special characters, rejection before process launch, explicit retry versus new clipboard link, failure classification and exact child environment keys. Browser tests now expect disk/source failures to stop after the first attempt, and network timeout to exercise the cookie-free fallback. These are behavioral tests, not complete acceptance evidence.

Still required:
- Socket limits, bounded retry delays/budgets, stalled process watchdog and cancellation of its timers; ensure large healthy downloads are not mistaken for hangs.
- Complete launch/missing engine classification and actionable messages; revisit generic versus YouTube retries and preserve one-run consent rules.
- Replace synchronous EngineUpdater.ytDlpVersion (readDataToEndOfFile/waitUntilExit on main actor) with bounded asynchronous process IO; test output/exit ordering, timeout and stale completions. Bound update work as needed while leaving its Homebrew replacement to WHO-238.
- Check raw malformed percent escapes, port/IPv6/IDN edge cases and retry URL display/session behavior during critical review.
- Actual UI inspection of the new failed-state actions, end-to-end download with restricted environment, timeout tests against local fixtures, normal build/signature check, final critical review and Linear evidence.

No installed app replacement, commit, push or release. Earlier completed task evidence remains in WHO-225-verification.md; current edits have not yet been certified as a complete WHO-226 implementation.

Native preview `local.Msvc8szo` built and passed ad-hoc signature check. Actual failed-state view displayed Try Again, Use new clipboard link and Use browser login without overlap. Clicking new clipboard link with no valid real clipboard URL produced explicit invalid-link help and started no download. That check exposed a retry button with no captured URL; the source now disables Try Again unless a failed job has an original URL. Final disabled-state rendering remains to inspect in the next preview. QA process 4247 was stopped. General low-contrast styling remains a WHO-229 concern; no sale-ready UI claim.

## Further progress: bounded asynchronous version query

Replaced EngineUpdater's synchronous version method with EngineVersionProbe. The query runs with controlled child environment and ignored external config/plugins, ordered asynchronous pipe events, maximum accepted output, a five-second deadline, and process-identity checks. Timeout/cancel kills only the query's owned process tree. Shutdown cancels the probe; stale updater exit callbacks now also require matching process identity.

Latest suite: **51 cases, 382 assertions, zero failures**. New tests cover no callback before EOF+exit, newline-free final output, invalid/oversized version text, cancellation, late exit after timeout, owned-child versus bystander signals. A real temporary executable that sleeps was launched: main-queue work ran while it slept; an accelerated injected deadline fired; the OS child was verified no longer running. This checks actual responsiveness and termination, not just a timeout message. The fixture was removed.

Remaining before completion: download watchdog/socket/retry budgets, classification/help completeness, raw URL edge review, end-to-end download with controlled environment, updated UI/normal build review. Also test the complete updater-success -> version-probe and shutdown/restart flows, bound Homebrew update duration, and inspect probe state on launch failure. The production five-second deadline is asserted with the fake clock; real timeout fixture uses 150 ms to avoid delaying the suite. No real Homebrew upgrade ran during this work.

## Further progress: download watchdog

The engine now gets a 15-second socket timeout, two network/fragment/extractor retries and one-second retry sleep. Actual installed yt-dlp parse_options accepted these flags and returned the intended values without invoking a download.

An owned, cancellable 10-second main-queue watchdog bounds each attempt: 120 seconds with no initial progress, 300 seconds with no new transfer record (records contain byte counts even for unknown totals), 1800 seconds without a processing-stage change, and six hours maximum attempt lifetime. Timeout uses existing owned cancellation/cleanup and retains the original URL for an explicit retry. Old callbacks and timers are guarded by run token. Completion, cancel and quit cancel the watchdog. The existing public attempt list has at most two attempts; browser-consented runs still have one. These limits must be documented in user help before task completion.

Latest suite: **54 cases, 398 assertions, zero failures**. Fetch timeout, hard cleanup, retained retry URL, stale exit/timer, advancing unknown-total bytes, repeated unchanged output, quiet merge allowance, processing stall and hard lifetime are tested with virtual time. These are not evidence of an actual network timeout or clean-Mac release. Real download/timeout smoke tests and the remaining updater/URL/help review are still required.
