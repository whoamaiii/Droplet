# WHO-228 — build and installation verification

28 September 2026. Local development workflow completed. Public signing/notarization remains WHO-237; customer update delivery remains WHO-238.

## Result

`build.sh` still only compiles, stages, signs and verifies a new complete candidate. It neither installs nor changes any running app or login service. Build output can be isolated with `DROPLET_BUILD_ROOT`.

`scripts/install_app.py` is a separate, explicit local installer requiring a destination. It validates bundle identity and signature before staging, uses macOS ditto to preserve extended attributes, verifies the staged copy, and uses Darwin atomic rename/exchange on the destination volume. Previous complete bundles and a transaction record are retained. Failed final verification restores the previous bundle. If rollback fails, both complete bundles remain available and the error identifies their recovery directory. Interrupted installation retains recovery material; there is no automatic crash-recovery claim or power-loss durability guarantee.

The installer shares the current app's runtime lock and holds a destination lock. It refuses a running target using the kernel executable path and refuses the loaded legacy KeepAlive job. It does not stop the app or unload/reload launchd: existing autostart is preserved without requiring restoration. Older app versions do not cooperate with the new runtime lock, so they must remain closed during the explicit local installation. There are no global process-name kills, quarantine-removal commands or app-launch commands in the installer.

README now explains the actual developer flow and recovery artifacts. It no longer presents historical respawn observations or broad site-count claims as current release proof. Smoke actions are compiled only into preview builds; a download smoke test requires an explicit URL, with no implicit public download. Public release builds exclude these controls.

## Acceptance evidence

| Requirement | Evidence |
| --- | --- |
| Separate build from installation | Build only writes a fresh output. Installer takes completed candidate and explicit destination. |
| Compiler/copy/sign failures preserve old app/autostart | Build test injects compiler, copy, signing and signature-verification failures. Mock launchctl is never called; old fixtures remain intact and failed output is cleaned. Installer tests separately exercise copy/signature/rename/final verification failure. |
| Complete bundle swap and rollback, no name-based termination | Tests use actual Darwin atomic exchange/rename; failed final verification restores old content. Rollback failure retains both versions. Installer never signals any user process. Real kernel-path running-target test passes. |
| Do not remove quarantine to bypass signing | Native metadata-copy test passes; installer uses ditto and strict codesign verification, with no xattr deletion. No public notarization claim. |
| README matches implementation | Build/install/preview/smoke/retry/cleanup boundaries documented and stale verification claim removed. |

## Checks performed

- **16 distribution test methods pass**, including four separate injected build failure scenarios, actual atomic swaps, initial installation, rollback, retained recovery after rollback failure, runtime/destination lock contention, symlink/identity rejection, metadata preservation and real-process path detection.
- Existing Swift checks: **66 cases, 459 assertions, zero failures**.
- Optimized preview build `local.4nfV42Hz` and normal build `local.ajK6CgJa` pass plist/signature checks.
- Actual ad-hoc-signed preview installed initially and then replaced in `~/Library/Developer/Droplet/InstallQA/WHO-228.Qxjd3WSu/Droplet.app`. Both current and retained previous bundles pass strict signature verification.
- CUA opened that installed artifact and displayed the native preview window. Its login-error QA button changed the visible view as expected. An install attempt while the actual app ran was refused. After final runtime-lock addition, another actual isolated installation succeeded.
- CUA's post-Quit observation reopened the test app; the resulting idle QA process 21842 was explicitly stopped. This is not recorded as new evidence for WHO-227 system termination.
- Installed production app was never replaced or stopped. Its executable SHA-256 remains `6f7da73a77227852337c839ebb41fc1c316f1464bc9bfda3f9fb204e1eb7248e`.

Critical review caught macOS metadata loss in generic Python copying, corrected to ditto, and added the shared runtime lock to close the current-version launch-versus-install gap. The test suite passed after these changes. No commit, push, publication, payment, LaunchAgent mutation or customer release occurred.
