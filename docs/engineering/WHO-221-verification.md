# WHO-221 verification — 28 September 2026

## Acceptance review

- Private, reversible baseline: 11 files and the original working-tree patch retained under `~/Library/Application Support/Droplet/DevelopmentBackups/20260928T115554Z-before-WHO-221`; SHA256 manifest verified. `.omo`, Info.plist and unrelated work preserved. Branch `codex/commercial-release`; no commit or push.
- Source responsibilities split into downloads/results, infrastructure, trial/licensing contracts, updater and UI. SwiftUI view definitions match the baseline exactly. Contracts do not imply implemented commercial features.
- Foundation-only executable checks run with the installed Command Line Tools: **20 cases, 55 assertions, 0 failures**. Covers fake process/API/clock/storage, plus a real subprocess/pipe. XCTest and Swift Testing are unavailable in these CLT, so the runner explicitly rejects assertion-free cases and exits nonzero for failures. All discovered case methods were checked against runner registration.
- Regression checks preserve process identity/run tokens, stale exit/output rejection, the original URL across retry, owned-process cleanup, updater isolation and recovery after launch failure.

## Built artifacts and actual UI

- Normal optimized app: `/Users/quentinthiessen/Library/Developer/Droplet/Builds/local.1Q1BVUFu/Droplet.app`. Plist lint and `codesign --verify --strict` pass. Linked libraries are Apple system libraries/frameworks. This is an **ad-hoc development signature**, not Developer ID or notarization.
- Separate preview: `/Users/quentinthiessen/Library/Developer/Droplet/Builds/local.1FZWEaty/Droplet.app`. Actual native window inspected via accessibility and screenshot: original droplet, example URL, Download, Downloads, updater and Quit controls render without clipping. The QA window hosts the identical view; normal builds exclude this window.
- Quit was exercised in the preview; its process exited. Original installed process PID 55748 remained alive. Installed executable SHA256 stayed `6f7da73a77227852337c839ebb41fc1c316f1464bc9bfda3f9fb204e1eb7248e`.
- A deliberately failed compiler returned exit 77 without creating a replacement bundle or changing the installed app. Shell syntax and `git diff --check` pass.

## Additional critical review

The extra pass found and corrected a possible cross-origin/plaintext HTTP redirect in the future license transport; origin/HTTPS policy now has explicit tests. Build staging was moved out of FileProvider-managed Documents because FinderInfo metadata made strict code signing fail. No quarantine stripping or security setting changes were used. Preview identity and a launch-agent guard prevent QA quit from unloading the installed app.

Known download defects, real trial/license behavior, Homebrew replacement, full popover interaction, clean-Mac installation, public signing and payment remain in their own open Linear tasks. This result establishes a verified foundation only. No real video download or paid unlock is claimed by these checks.
