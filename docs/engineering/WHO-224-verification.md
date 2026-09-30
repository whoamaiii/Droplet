# WHO-224 verification — 28 September 2026

## Acceptance evidence

1. **Verified DownloadResult:** carries source URL, extractor/media identity, actual published URL, byte count, format/codecs/duration and `isNewFile`. The result is created only after native media verification and atomic publication. Each job uses fresh staging, so an old output is never implicitly reused or labelled new. A deliberate repeat produces a new safely named file; identity-based trial deduplication remains WHO-231.
2. **Safe naming and publication:** private per-attempt staging avoids shared partial files. Sanitized Unicode names are bounded by UTF-8 bytes and include an identity hash. Atomic `link(2)` never replaces a destination; collisions receive numeric suffixes. Tests preserve two same-title/same-ID files and their bytes. Outside-workspace paths, symlinks, empty files and changed size are rejected.
3. **Playable media structure:** AVFoundation checks MP4 brand, positive finite duration, H.264 video and optional AAC audio, then decodes the first sample of every media track. Corrupt/truncated and unsupported fixtures fail. This is structure plus initial-sample validation, not full decoding of every frame of an arbitrary file. Done requires successful exit, drained output, valid identity/result, successful verification and publication.
4. **Filesystem failures and Finder:** ENOSPC/EACCES/ENOENT injected at the atomic publication boundary after real-media validation produce actionable manager failures, no result and cleaned staging. Other tests cover moved/removed folder, unsafe paths and long Unicode names. Actual Show in Finder action selects the exact result file, verified in Finder accessibility state.
5. **Format/audio policy:** selector supports AVC/H264 and MP4A/AAC labels, combined/separate/silent sources, provisional unknown labels followed by native verification, and explicit rejection of incompatible media. Source audio provenance is included in the result protocol. Known source audio absent from the actual file rejects publication rather than silently saving a muted substitute. Missing upstream metadata cannot prove what streams the service omitted.

## Tests and built artifact

- `./scripts/test.sh`: **38 cases, 241 assertions, zero failures**.
- `python3 scripts/verify-format-policy.py`: eight selector scenarios against installed yt-dlp pass.
- `python3 scripts/verify-engine-protocol.py`: 13 real structured events, production selector, media identity/audio provenance, and final H264/AAC file pass.
- Normal optimized app: `~/Library/Developer/Droplet/Builds/local.kpXSIqBa/Droplet.app`. Plist and strict ad-hoc signature verification pass. Shell syntax and `git diff --check` pass. No public-signing/notarization claim.

## Actual app and Finder proof

Preview build `local.rzML9y8V/Droplet.app` downloaded self-generated one-second video/audio from loopback through the real manager, yt-dlp, native verification and publication. Preview-specific configuration constrained the URL to 127.0.0.1, output to a dedicated UIQA directory and cookie discovery to none. This code/configuration is excluded from normal builds.

The app showed Saved to Downloads. Clicking Show in Finder opened the fixture output folder with **Droplet-QA [84c468c79207].mp4 selected**, confirmed by native accessibility state. File retained as evidence at:

`/Users/quentinthiessen/Library/Developer/Droplet/UIQA/e9db484e-0f1a-48c4-aaba-6f25107e63a7/Downloads/Droplet-QA [84c468c79207].mp4`

ffprobe: H264 video, AAC audio, 1.000 seconds, 11,859 bytes. Independent FFmpeg full decode of this fixture returned no errors. The fixture Finder window was closed; preview and loopback server were stopped. The source/finished fixture remains as useful verification evidence.

Installed app hash remains `6f7da73a77227852337c839ebb41fc1c316f1464bc9bfda3f9fb204e1eb7248e`; original process PID 55748 stayed running. No install, commit, push or release.

## Extra review and corrections

| Finding | Correction and evidence |
|---|---|
| Video-only fallback could silently lose incompatible audio | Source audio provenance checked against native media; manager failure test with silent H264 and known source Opus passes |
| Generic sources use alternative/unknown codec labels | Alias-aware selector plus real media verification; eight real-selector cases pass |
| Cancel during suspended verification could publish stale output | Task cancellation plus run-token check immediately before publication; held-verification/replacement test passes |
| Cancel then Quit previously discarded delayed cleanup | Every pending cleanup is retained and flushed once; two cancelled jobs, owned descendants and no repeated signals tested |
| Quit during suspended verification could leave staging | Validation workspaces tracked independently; synchronous quit cleanup verified before suspended verifier is released |
| User yt-dlp config/plugins could alter the verified output contract | Explicit ignore-config/no-plugin-dirs added for deterministic execution; remaining retry/timeouts/privacy work stays in WHO-225/226 |

No unresolved finding prevents WHO-224's five acceptance criteria. Graceful cancellation/quit are covered here. Forced process death/power loss can leave private staging; crash recovery, quota journaling and broader process lifecycle certification remain in WHO-227/231. Nothing here certifies real-site coverage, clean-machine installation, payment or commercial readiness.
