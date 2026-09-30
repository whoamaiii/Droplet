# WHO-223 verification — 28 September 2026

## Acceptance evidence

- **Byte framing and EOF:** `ProcessLineBuffer` preserves incomplete raw UTF-8 across reads, recognizes CR/LF/CRLF and flushes the final line exactly once. Records are bounded to 1 MiB. `ProcessOutputCoordinator` submits framed records before completion and requires both pipe EOF and process exit. Per-attempt run tokens and process identity reject stale deliveries.
- **Structured engine output:** `DownloadOutputProtocol` supplies JSON progress/postprocess templates and `after_move` result output, prefixed with a per-attempt UUID marker. Ordinary percentage/destination prose is ignored. JSON escaping preserves Unicode, embedded quotes and newlines. Missing values use the explicit `null` placeholder. Only diagnostic ERROR text retains text parsing.
- **Real stages:** fetching, video, audio, combined media, merge, other processing and finalization are separate. Unknown progress uses an activity indicator. Transfer progress is capped below completion; the Done transition requires drained output, successful exit, no recorded output error, and a reported nonempty regular file. Full media integrity, collision handling and new-file accounting remain WHO-224.
- **Regression coverage:** every split boundary of a multilingual record, one-byte reads, multiple lines, CR/LF, unterminated EOF, EOF before/after exit, stale callbacks, cancellation/replacement, malformed messages, unknown totals, boolean/non-numeric byte values, unsuccessful output and successful final-path handling.

## Results

`./scripts/test.sh`: **29 cases, 156 assertions, zero failures**. Includes a real Foundation subprocess/pipe. A synthetic nonempty file is used only to test the basic final-file gate; it is not claimed as validated media.

`python3 scripts/verify-engine-protocol.py`: **13 real structured events**, video/audio/Merger/result observed. The script generated one-second local video and audio, served them on loopback, and ran installed yt-dlp 2026.8.19 with FFmpeg. The final file's audio and video streams were confirmed by ffprobe. Production Swift template literals are read directly by this fixture. No public video service, cookies or user Downloads files were used; temporary files and the local server were cleaned up.

Optimized app: `~/Library/Developer/Droplet/Builds/local.pOcSgRid/Droplet.app`; plist lint and strict ad-hoc signature verification pass. `git diff --check` passes. Public notarization is not claimed.

Actual preview UI: video 42%, audio 99%, and merge were inspected using native accessibility and screenshots. Final UI revision at `local.Yn4wLWYT/Droplet.app` shows an activity indicator, merge label and Cancel without clipping. QA controls are compile-time preview-only and use visibly labelled synthetic states; they do not prove a live network download through the UI. The separately exercised real engine fixture proves template compatibility. The preview was stopped afterward.

Installed app stayed at SHA256 `6f7da73a77227852337c839ebb41fc1c316f1464bc9bfda3f9fb204e1eb7248e`, PID 55748. No install, commit, push or release.

## Extra critical review

| Finding | Resolution |
|---|---|
| yt-dlp's missing numeric fields emitted `NA`, invalid JSON | Explicit `null` placeholder; verified against the actual engine |
| A process-exit callback can precede final pipe output | Serialized line delivery and dual EOF/exit completion; both orders tested |
| Transfer completion could appear to mean saved file | Stage-specific progress, basic final-file gate, unknown-progress indicator |
| Malformed output or ERROR with exit zero could appear successful | Both reject success; regression tests pass |
| A stale callback could alter a replacement run | Run token plus process identity retained and tested |

No unresolved finding prevents these four acceptance criteria. Remaining release work includes WHO-224's media validation/collisions/trial accounting and WHO-226's bounded retry/timeouts; this issue does not certify overall download reliability, provider support or commercial readiness.

Reference: [official yt-dlp structured output guidance](https://github.com/yt-dlp/yt-dlp#embedding-yt-dlp), checked during implementation; installed-engine fixture is the compatibility evidence.
