# Droplet takeover verification — 2026-09-30

## Implemented

Persistent download/trial state is now created only after successful menu-bar instance-lock acquisition. Dormant contenders do not recover the active owner’s journal or retain stale quota state. Dormant shutdown does not initialize a download manager.

Regression: `Contender preserves active trial journal` verifies an occupied lock never invokes the persistent-state factory or changes the active reservation, then verifies one fresh initialization after ownership transfers.

## Verification

- Swift checks: 78 cases, 521 assertions, 0 failures.
- Distribution checks: 16 tests, OK.
- Release preview build succeeded, plist validation and strict ad-hoc signature verification succeeded.
- Isolated QA bundle: `/Users/quentinthiessen/Library/Developer/Droplet/Builds/local.mgE0lido/Droplet.app`.
- Fixture root: `/Users/quentinthiessen/Library/Developer/Droplet/UIQA/6c2cbdf4-e156-4be4-bcde-44fd83ac24be`.
- Tracked diff whitespace check passed. New files were compiled by the Swift checks/build.
- Installed app was not replaced.

## Remaining verification / blockers

Native UI selection (`cua.getApp` for the QA bundle) returned no state, hung for 1544 seconds, and was aborted. Launch success, screenshots, real download-through-UI, light/dark states, quota exhaustion through UI, and saved-file actions remain unverified for this build. No substitute UI technology was used.

Payment provider/product configuration, approved purchase terms, production signing/notarization, customer engine packaging and clean-Mac/customer-distribution verification remain release work. This is a local development build; paid activation remains unavailable and is not claimed production-ready.

## Final code-only verification

- Swift checks: **83 cases, 546 assertions, 0 failures**. Added dormant successor fresh-quota and failed recovery-write journal preservation checks; registered previously unlisted manager tests for corrupted state, update/download exclusion, cancellation/retry accounting and publication-write failures.
- Actual loopback engine QA: **27 assertions, 0 failures**. Real yt-dlp/FFmpeg via DownloadManager: cancelled attempt retains all credits and produces no final file; three successful H264/AAC downloads match source bytes; collision-safe filenames preserve all three files; disk quota reload matches remaining credits; reopening preserves success; fourth attempt launches no process; no temporary workspaces remain.
- Fixture/results root: `/Users/quentinthiessen/Library/Developer/Droplet/UIQA/c55f6e62-79db-46b9-bcde-3e23e318ca33`, outputs in `CodeQA`, accounting in `CodeTrial`.
- Distribution checks after final code: **16 tests, OK**.
- Final ordinary release bundle, **without DROPLET_PREVIEW**: `/Users/quentinthiessen/Library/Developer/Droplet/Builds/local.ERR73gZm/Droplet.app`. Compilation, plist and strict ad-hoc signature checks passed. Build does not install or launch it.
- Static accessibility review: decorative shapes hidden; icon actions named; progress percentage announced; Return defaults, Command-period cancel, Command-comma settings and Command-Q quit present; browser dialog supports Escape/Return and profile-error focus. System Reduce Motion overrides preview preferences; main-view transactions disable animation and decorative repeat motion is suppressed. Runtime focus order, VoiceOver, contrast and clipping still require native UI observation.
- README corrected to reflect persistent success and implemented local quota; historical WHO-229 evidence retained with current follow-up.

### Reproducing code-only loopback QA

Start `python3 scripts/serve-ui-fixture.py --chunk-delay 0.1` in a persistent test terminal. Use the returned loopback URL and fixture root with `.build/debug/DropletChecks --loopback-qa <url> <root>`. Each run requires a fresh fixture root and creates only isolated `CodeQA` and `CodeTrial` directories. No browser cookies, user clipboard, paid credentials or installed app are used.

All remaining runtime-native checks remain unverified because of the 1544-second CUA hang. No new CUA call was made for this follow-up. No payment, new external service, publication, production credential or installed-app replacement occurred.
