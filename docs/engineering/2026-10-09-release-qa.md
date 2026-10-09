# Droplet release QA on a real Mac — 2026-10-09

The first full run of the customer release path (`scripts/first-release.sh`) on
real hardware, followed by manual checks of the installed app.

## Environment

- Apple M5 (Mac17,2), macOS 27.2 (26B5091g), Swift 6.2.3.
- Checkout `c965893`, then `8696a29` (engine pin committed during the run).
- Release mode: direct (free self-signed "Droplet Signing" certificate), universal
  build, test bundle ID `invalid.droplet-test.droplet`, no store configured
  (`ALLOW_UNLICENSED=1`), installed in `/Applications`.

## Problems found and fixed during the run

Each one stopped the run on the Mac; each fix was pushed before the next try.

| Symptom | Cause | Fix |
| --- | --- | --- |
| "unable to type-check this expression in reasonable time" (`DownloadManager.swift`, `MediaVerifierTests.swift`) | Swift 6.2's type checker gives up on long `+` array chains | Arguments built in steps |
| Checks hung ("Alarm clock") | Test FFmpeg read the terminal and was stopped (SIGTTIN) under a pipe | `-nostdin`, null stdin for every FFmpeg/yt-dlp child; runner watchdog names the stuck check |
| Python `UnicodeDecodeError` in installer tests | Non-ASCII installer output under the Mac's locale | Installer is plain ASCII; tests decode bytes leniently |
| `first-release.sh`: "unbound variable", `release.sh`: "unexpected token `('" | macOS ships bash 3.2 | No empty arrays; regex patterns in variables; tests run under bash 3.2 |

## Automated results (on the Mac)

- Swift checks: **99 cases, 710 assertions, 0 failures**.
- Distribution checks: **29 tests, OK**.
- Release build: universal app, helpers and app signed, signatures verify; DMG,
  zip, `.sha256` files and `install.sh` produced.

## Bundled engine: PASS

Versions read from `Droplet.app/Contents/Helpers`: yt-dlp 2026.08.19, Deno 2.9.7,
FFmpeg 9.0.2. Using only those helpers, the Blender Foundation's Big Buck Bunny
upload (YouTube `aqz-KE-bpKQ`, CC BY 3.0) downloaded to MP4; ffprobe reports
H.264 video and AAC audio. No warnings.

## Manual checks: 12 of 13 passed

| # | Check | Result |
| --- | --- | --- |
| 1 | Welcome window closes with "Got it" | PASS |
| 2 | Bubble shows "3 of 3 free downloads left" | PASS |
| 3 | YouTube download through the app: progress, "Video saved", MP4 plays in QuickTime with sound | PASS |
| 4 | Show in Finder, Open video | PASS |
| 5 | Cancel a running download; counter unchanged | PASS |
| 6 | Non-link clipboard gives a clear error; counter unchanged | PASS |
| 7 | Download from a second site (Vimeo) | **FAIL**, see below |
| 8 | Downloads use up the trial; the next one is refused (no Buy button, as no store is configured) | PASS |
| 9 | Settings: version, Choose folder, Open at login, third-party licenses folder | PASS |
| 10 | Engine update button ends with a version or a clear message | PASS |
| 11 | Quit leaves no Droplet, yt-dlp, Deno or helper processes | PASS |
| 12 | Reopen: trial count and settings kept, no new permission prompts | PASS |
| 13 | Rerun `first-release.sh` and reinstall: finished steps skipped, no folder or Keychain prompts again | PASS |

**Check 7.** Vimeo now asks for sign-in or a human check, and the bundled yt-dlp
reports that Vimeo's web client only works when logged in. Droplet showed its
sign-in message. This is a Vimeo change, not a Droplet defect, but Vimeo should
not be advertised as supported. A second site has not been verified yet.

## Notes

- The Codex computer-use tool timed out (`-10005 timeoutReached`) on Droplet and the
  menu bar; the app clicks were made by hand and checked with screenshots and
  terminal output.
- `hdiutil` prints a deprecation warning while making the DMG. The DMG is still
  produced; moving to `diskutil image` is optional.
- After the run, the FFmpeg pin was given its exact release (9.0.2), source archive
  and build script, which pinning now records automatically.

## Not covered by this run

- Installing with `curl -fsSL …/install.sh | bash` from the real website (the
  installer itself is covered by the distribution tests with a local server).
- License activation against a real Lemon Squeezy store and checkout link.
- A clean second Mac and an Intel Mac.
