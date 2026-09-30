# Droplet implementation boundaries

WHO-221, 28 September 2026. This is a foundation refactor, not a paid release.

## Build and tests

- `./build.sh` produces a new optimized, ad-hoc-signed app under `~/Library/Developer/Droplet/Builds/`. It does not install, launch, stop processes, alter launchd, or strip quarantine.
- `./build.sh --preview` produces a separate bundle identity and a QA-only window hosting the unchanged view with an example URL. Its Quit action cannot unload the installed Droplet LaunchAgent. This checks rendering, not all menu-bar popover interactions. The window code is excluded from normal builds.
- `./scripts/test.sh` runs the Foundation-only `DropletChecks` executable. This Mac has Command Line Tools but no XCTest or Swift Testing modules. The small runner reports each case, assertion counts and a nonzero exit on failure, with a 60-second watchdog. Tests do not enter the shipped app target.
- Swift Package Manager builds the app from `Sources/`. The obsolete monolithic root `main.swift` has been replaced, not retained as a second source of truth.

## Responsibilities

`Sources/Droplet/main.swift` calls the library bootstrap. AppKit lifecycle and SwiftUI visuals are in `DropletKit/UI`. The visual definitions were moved without changes.

`Downloads/DownloadManager.swift` coordinates the existing download state machine. `DownloadEnvironment` supplies process creation, clipboard access, paths, signals, sound and time. Tests inject fakes and never read the real clipboard/browser profiles or send network requests to video sites.

`Updating/EngineUpdater.swift` owns the existing update action independently of download state. The view still observes the manager's update note. Homebrew is retained for this foundation task and must be replaced in WHO-238; this build is not ready for customers.

`Infrastructure/ProcessInspector.swift` retains kernel-derived process ownership and instance ranking. No global name-based kill has been introduced.

`Downloads/DownloadResult.swift` now carries verified media, identity and the actual published URL. WHO-224 integrates per-attempt staging, native media checks and atomic publication before success; trial accounting is still a later task.

`Trial/TrialAccounting.swift` and `Licensing/LicenseClient.swift` define the boundaries for later quota and license implementations. They contain no fake unlock, payment, quota enforcement or hardcoded success. WHO-231 through WHO-236 remain incomplete.

`Infrastructure/HTTPTransport.swift` handles HTTPS requests and preserves HTTP error status versus network failure. Product binding belongs in the license adapter. `StateRepository.swift` decodes stored JSON and propagates locked, corrupt and failed-write errors instead of interpreting them as a new trial. Production Keychain storage is a later task; the current tests use isolated memory storage.

## Scope and limitations

Known audit findings are still tracked in Linear, including broader cancellation edge cases, crash recovery and public signing. Moving code does not resolve these findings. No task is Done merely because a protocol or file exists.

The source backup and working-tree patch from before the refactor are private under `~/Library/Application Support/Droplet/DevelopmentBackups/20260928T115554Z-before-WHO-221`. The SHA256 manifest verifies 11 baseline files. No commit or push was made.

## Gate before moving to another Linear task

1. Check every acceptance criterion against the actual implementation.
2. Run behavior-oriented tests, including old-callback and process-ownership regressions.
3. Build the actual app and inspect the resulting bundle and running UI as applicable.
4. Review the diff separately for incorrect assumptions, regressions and missing checks.
5. Record exact evidence and unresolved limitations in the task. Only then mark Done.

If a required check is inaccessible or fails, keep the task open. A successful compiler or a mock is not proof of customer installation, real payment, provider approval or a working license.

WHO-223 now supplies structured per-attempt engine events, bounded byte framing and ordered EOF/exit completion. See [verification](WHO-223-verification.md). Preview builds include labelled controls for visual inspection of download stages; those controls are excluded from normal builds.

WHO-224 acceptance and actual app/Finder evidence are recorded in [verification](WHO-224-verification.md). Normal builds exclude preview-only loopback fixture configuration.

WHO-225 removes automatic cookie discovery/fallback. BrowserLoginConsent binds an explicit browser/profile choice to one URL and one run; the dedicated form performs no IO before consent. See [verification](WHO-225-verification.md), including real engine parsing and native download evidence.

WHO-226 isolates the engine environment, validates all URL entry points, classifies retryable failures and bounds engine/version/update operations. See [verification](WHO-226-verification.md) for exact deadlines, actual app checks and remaining release gates.
