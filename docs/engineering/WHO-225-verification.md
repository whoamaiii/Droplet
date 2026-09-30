# WHO-225 — explicit one-download browser consent

Verified 28 September 2026. This task is a privacy boundary, not certification of every authenticated video service or a sale-ready release.

## Acceptance evidence

- Ordinary downloads use `--no-cookies --no-cookies-from-browser`. Browser discovery and automatic cookie fallback were removed. `--ignore-config` and `--no-plugin-dirs` isolate engine configuration; netrc is disabled by the real engine's default. No Full Disk Access request exists in the ordinary flow.
- After failure, a dedicated titled form explains local cookie reading, matching site requests and possible macOS access prompts. It displays the exact URL and allows one browser/profile. Only the explicit Use login once action constructs URL-bound consent. Cancel, closing the window and editing/selecting do not start a process. No choice is persisted. Ordinary subsequent downloads return to cookie-free arguments.
- A consented run has one attempt and no fallback to other profiles. Cancellation terminates its owned process tree, prevents retry and removes consent from subsequent ordinary runs. Profile control characters, colons, Safari custom profiles and credential-bearing/non-HTTP URLs are rejected before process creation.
- Current code has no downloader-to-license/support/telemetry data path. LicenseClient is still a protocol; this does not certify a future provider integration. Recheck this boundary in WHO-232/236. Browser history is never requested by Droplet.
- Injected network, disk-full and unsupported-URL failures exercise both ordinary YouTube attempts without any browser-cookie option. README and failure help no longer recommend weakening macOS protections.

## Tests and actual UI

`./scripts/test.sh`: **42 cases, 298 assertions, 0 failures**. Includes positive URL-bound consent, no carry-over, cancellation/revocation, malformed inputs, and failures without cookie fallback, plus existing subprocess and media regressions.

`python3 scripts/verify-browser-options.py`: real installed yt-dlp parser accepts current production privacy flags and all five supported browser choices. Public options resolve to no browser cookies, cookie file or netrc. Parsing performs no cookie extraction or network requests.

Native preview `local.seDUIssR`: visually checked the complete explanation, URL, Safari default, Chrome selection and Profile 2 input. Cancel returned to failure without download. Reopening reset to Safari/default; window close also returned without starting. No real browser-access consent was granted in this test.

Native preview `local.W3iOEa5T`: clicked Download against a self-generated loopback MP4 after the final engine-argument fix. App displayed Saved to Downloads. Actual output:

`/Users/quentinthiessen/Library/Developer/Droplet/UIQA/7c7e151c-07cd-49d6-abc1-f8e6d2d67024/Downloads/Droplet-QA [84c468c79207].mp4`

11,859 bytes, H.264 video and AAC audio. Full FFmpeg decode passed; no attempt staging directories remained. Test app and loopback server were stopped afterward. The fixture is retained as evidence.

Normal optimized build and strict ad-hoc signature verification passed:
`/Users/quentinthiessen/Library/Developer/Droplet/Builds/local.9YZTb3Gc/Droplet.app`

## Extra critical review and corrections

The first native alert lost usable dialog state during browser selection. Replaced it with the tested titled window. A real engine-parser check then rejected `--no-netrc`, despite fake-process tests accepting it. Removed that unsupported option and verified the engine default with ignored external configuration. Rebuilt and performed the actual UI download after the fix. The issue was not closed on the earlier passing mock tests.

Reviewed consent construction, every start/retry path, callback URL binding, cancel ownership, logging, README and present license transport boundary. No URL/profile/cookie logging or new outbound support channel was added. Broader retry policy is still WHO-226.

Installed app preserved, running PID 55748 at final check. Its executable SHA256 remained `6f7da73a77227852337c839ebb41fc1c316f1464bc9bfda3f9fb204e1eb7248e`. No install, commit, push, public signing or release performed.

## Limits

No real private browser profile was opened, and no protected service login was exercised. Provider-specific cookie compatibility and supported-site QA remain WHO-245. Current engine is the developer's Homebrew install; bundled engine delivery remains WHO-222. The completed claim is explicit, optional, single-run access control with a working ordinary download, not universal authenticated download support.
