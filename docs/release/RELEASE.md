# Releasing Droplet on your website

This is the path from this repository to a DMG that customers can download
from your site, open without Gatekeeper warnings, try for free, and buy.

The code side is done: the engine ships inside the app, the in-app engine
update no longer uses Homebrew, and Lemon Squeezy license activation is built
in. What remains needs your accounts and decisions. Do the steps in order.

## 1. One-time setup

### Apple Developer ID (required — otherwise macOS blocks the app)

1. Join the [Apple Developer Program](https://developer.apple.com/programs/enroll/) (US$99/year).
2. In Xcode → Settings → Accounts → your team → **Manage Certificates…** → **+** →
   **Developer ID Application**. Check it is in your keychain:
   ```bash
   security find-identity -v -p codesigning
   # "Developer ID Application: Your Name (TEAMID1234)"
   ```
3. Create an app-specific password at [appleid.apple.com](https://appleid.apple.com)
   (Sign-In and Security → App-Specific Passwords), then store notarization
   credentials once:
   ```bash
   xcrun notarytool store-credentials droplet-notary \
     --apple-id you@example.com --team-id TEAMID1234 --password abcd-efgh-ijkl-mnop
   ```

### App identity

Pick a permanent bundle identifier from a domain you control, for example
`com.yourdomain.droplet`. Never change it after the first public release:
settings, the Keychain license and the login item are tied to it. The
development builds use `local.quentinthiessen.droplet` and the release script
refuses `local.*`, `com.example*` and `*.preview` identifiers.

### Lemon Squeezy (payments and license keys)

1. Create a store and complete the store activation. **Check first** that a
   video-downloader app is acceptable under their
   [prohibited products](https://docs.lemonsqueezy.com/help/getting-started/prohibited-products)
   rules; they must approve both the store and the product.
2. Create the product (for example "Droplet", US$4.99, single payment).
   In the product's settings, enable **Generate license keys** and set the
   activation limit (for example 2 Macs) and "no expiry".
3. Collect for `release.env`:
   - **Store ID** — Settings → Stores (numeric).
   - **Product ID** and optional **Variant ID** — numeric IDs of the product.
     Leave the variant empty to accept every variant of the product.
   - **Checkout link** — the product's Share / buy URL.
4. Use **test mode** for your first end-to-end test: buy with a test card,
   take the key from the receipt email, activate it in Droplet, deactivate it.

How the app uses it: the key is activated with Lemon Squeezy's public License
API (no secret API key is shipped). The app checks that the key belongs to
your store and product, stores it in the Keychain, re-checks at most once a
day, and keeps working for 30 days without internet. Only an authoritative
answer from Lemon Squeezy (unknown key, disabled, refunded, deactivated)
removes it. Settings → License has **Buy**, **Activate**, **Check license**
and **Deactivate this Mac**.

### Your website needs

- A download link to `Droplet-<version>.dmg` and its SHA-256 (from `dist/`).
- System requirements: **macOS 14 Sonoma or later, Apple Silicon or Intel.**
- What the trial is (3 successfully saved videos) and the price.
- A **privacy policy** page (draft: [PRIVACY-POLICY-TEMPLATE.md](PRIVACY-POLICY-TEMPLATE.md)).
- Terms / refund policy (Lemon Squeezy is the merchant of record; link their
  buyer terms and state your refund promise).
- A support email address.
- A clear statement that customers may only download videos they have the
  right to download, and that site compatibility can change.
- Third-party licenses and a source offer for the bundled GPL programs
  (the app shows them under Settings → Third-party licenses; link the same
  texts from the site).

## 2. Pin the download engine

The app bundles yt-dlp (standalone macOS build), FFmpeg/ffprobe and Deno (the
JavaScript runtime yt-dlp needs for YouTube). Their exact files are pinned by
SHA-256 in `engine.lock.json`:

```bash
python3 scripts/fetch_engine.py --pin --yt-dlp latest --deno latest --ffmpeg
git diff engine.lock.json      # review, then commit
```

The yt-dlp binary is cross-checked against the hash list the yt-dlp project
publishes. Re-pin before every release so customers start with a current yt-dlp.

**FFmpeg licensing decision.** The default URLs in `engine.lock.json` point to
prebuilt GPL FFmpeg builds for Apple Silicon and Intel. Droplet only remuxes
(copies H.264/AAC streams into MP4, no encoding), so an LGPL build is enough
and has lighter obligations. Whichever you ship, you must include its license
and offer its source (`SOURCES.txt` in the app lists the links). Replace the
`ffmpeg.download` URLs if you build or choose a different FFmpeg.

**Size.** Deno is large (roughly 100 MB per architecture). Without it, many
YouTube videos fail. To make a smaller download you can ship separate Apple
Silicon and Intel DMGs (`DROPLET_ARCH=arm64` / `x86_64`) instead of one
universal DMG.

## 3. Build, sign and notarize

```bash
cp release.env.example release.env   # once; it is git-ignored
$EDITOR release.env                  # bundle ID, version, Developer ID, store IDs, links
./scripts/release.sh
```

The script validates the configuration first, then:

1. builds `Droplet` for arm64 and x86_64 and joins them with `lipo`;
2. assembles `Droplet.app` with the icon, third-party notices and the pinned
   helpers in `Contents/Helpers` (each helper is run once as a smoke test);
3. writes your bundle ID, version, store IDs and links into `Info.plist`;
4. signs every helper and the app with your Developer ID and the hardened
   runtime (yt-dlp and Deno get the minimal entitlements in
   `Resources/Entitlements/`);
5. notarizes and staples the app, builds the DMG, signs, notarizes and
   staples the DMG, and checks both with Gatekeeper (`spctl`);
6. writes `dist/Droplet-<version>.dmg` and `dist/Droplet-<version>.dmg.sha256`.

`DEVELOPER_ID_APPLICATION="-"` makes an unsigned local test build before your
Apple account is ready. It is not for customers. `VALIDATE_ONLY=1` checks
the configuration without building.

If notarization is rejected, the script prints Apple's log. The usual causes
are an unsigned helper, a missing secure timestamp, or a wrong identity.

## 4. Test like a customer (before publishing)

On a Mac **without** Homebrew, Xcode or your developer account (or a fresh
macOS user account):

- [ ] Download the DMG from your website in Safari, open it, drag Droplet to
      Applications, open it: no "cannot be opened" or "damaged" warning.
- [ ] The welcome window appears and the droplet is in the menu bar.
- [ ] Download a video you have the right to download from YouTube and from
      at least two other sites you plan to advertise. Each saves as a
      playable MP4 with sound; the counter goes 3 → 2 → 1 → 0.
- [ ] A failed or cancelled download does not use a free download.
- [ ] After the third video, Download shows **Buy Droplet** / **Enter license
      key…**. Buy in test mode, activate the emailed key: the next download works.
- [ ] Settings → **Deactivate this Mac**, then activate the same key again
      (and on a second Mac, up to your activation limit).
- [ ] Turn off Wi-Fi: a licensed Droplet keeps working.
- [ ] Footer update button: "yt-dlp … ✓"; a download afterwards still works.
- [ ] Settings → **Open Droplet at login**, log out and in: Droplet starts.
- [ ] Quit from the bubble: no Droplet, yt-dlp, ffmpeg or deno processes remain.
- [ ] Running Droplet straight from the DMG shows "Move Droplet to your
      Applications folder".

Then switch Lemon Squeezy to live mode, make one real purchase, refund it, and
confirm the refunded key stops working after the next daily check.

## 5. Every later release

1. Increase `DROPLET_VERSION` and `DROPLET_BUILD` in `release.env`.
2. Re-pin the engine (step 2) and commit `engine.lock.json`.
3. `./scripts/release.sh`, run the checklist above (at least the install,
   one download and license activation), upload the new DMG and checksum.

When a site breaks, customers can press the update button in the bubble: it
updates yt-dlp in the background without a new app release. A new app
release with a newer bundled engine automatically takes precedence over an
older in-app update.

## Not included yet (decide before or after v1)

- **App self-update.** There is no Sparkle-style updater for the app itself;
  customers download new versions from your site. The engine updates itself.
  Adding [Sparkle](https://sparkle-project.org) later needs an EdDSA key and
  an appcast feed on your website.
- **Mac App Store.** Not suitable for this design (bundled downloader,
  browser cookies, App Review guideline 5.2.3).
- **Tamper-proof trial.** The free-download count is stored locally and can
  be reset by a determined user. That is a deliberate trade-off for a
  US$5 app (see the launch plan).
- **Legal review.** Payment-provider acceptance, consumer terms in your
  country, tax registration, and the GPL obligations of the bundled programs
  still need your own check (launch plan WHO-216/217/218/240).
