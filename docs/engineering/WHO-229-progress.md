# WHO-229 — customer experience, in progress

28 September 2026. This issue is not Done and no paid-release readiness is claimed.

Implemented so far:

- A native Settings/About window with actual bundle version, selected output path, native folder picker and Getting started entry.
- Folder selection uses a local bookmark. Restore failures are explicit and prevent silently downloading into an unintended default folder; a fresh choice recovers. Selection is disabled during an active download. Existing file verification/atomic publication still uses the chosen destination.
- First-use welcome window explains the menu-bar icon, clipboard workflow, folder permissions and optional per-download browser login. Dismissal is stored only when Got it is pressed. Current copy explicitly describes development status; it does not falsely claim an implemented paid trial.
- The UI reflects the chosen folder, removes the unsupported 1000+ sites claim, provides named icon actions, Command-comma settings and Command-Q quit, hides decorative shapes from accessibility, and respects Reduce Motion for the decorative droplet/button animation.
- Saved-result UI has Show in Finder plus Open video using the actual verified result URL; missing/unopenable results receive an explanation. The latter is compiled but still needs a real completed-file UI check.

Verified:

- 68 Swift test cases / 475 assertions passed after bookmark recovery and active-job protection were added. Tests cover missing/corrupt bookmark, valid persistence, failed choice preserving the previous choice, blocked mid-download change, and recovery without silently saving elsewhere.
- Preview `local.Py6DOgU3` opened through CUA. Settings and native NSOpenPanel worked; an explicit test folder under `~/Library/Developer/Droplet/InstallQA/WHO-228.Qxjd3WSu` was selected and displayed.
- CUA inspected the actual dark-mode Settings and Welcome windows. One truncated settings sentence was corrected with wrapping and additional height.
- Preview `local.xYljEdtl` restored that folder on a fresh launch. The corrected settings screenshot showed the full text without truncation. Got it was exercised; subsequent launch showed the main view instead of reopening onboarding.
- Both QA instances were closed using their own Quit button. Post-quit native observation is deliberately avoided because CUA can relaunch the selected app; process inspection is used to verify exit instead.

Still open before Done:

- Approved trial/license terms, actual three-successful-download entitlement integration, final customer copy and working license/support surface. Current development copy is not a release substitute. A product-choice question is pending in the conversation.
- Light-mode and Reduce Motion runtime visual checks, keyboard navigation, long/error/merge layouts and real success Open/Reveal with auto-close/reopen after these changes.
- Folder permission denial, disconnect/move and actual completed download to a user-chosen folder in native UI. Unit tests do not substitute for all of these.
- Final normal build and critical review of the completed issue.

User authorized proceeding beyond WHO-227 after confirming manual sleep testing. WHO-227 retains other unresolved observations; it was not falsely marked Done. WHO-228 is independently complete. The original installed app remains untouched. No paid checkout, license activation, signing account, commit, push or release has been performed.

## 30 September follow-up

The three-successful-download local quota is now integrated, with a journal before atomic publication, persistent crash reconciliation, blocked starts on state errors, and fresh state only after instance ownership. Failed/cancelled attempts preserve credits. Saved success remains visible across reopening. Paid activation is deliberately unavailable; no provider or checkout is configured.

Latest verification: 83 cases / 546 assertions / 0 failures, 16 distribution tests, plus real loopback DownloadManager QA with 27 assertions / 0 failures. A normal non-preview release build passed plist and strict ad-hoc signing checks. See `2026-09-30-takeover-verification.md` for paths, exact coverage and remaining native UI limitations. Historical checks above do not certify the latest UI.
