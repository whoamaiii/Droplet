# Releasing Droplet on your website

Droplet is distributed **from your own website**, never through the Mac App
Store, and **without a paid Apple developer account**. Customers install it
with one line in Terminal:

```bash
curl -fsSL https://yourdomain.com/droplet/install.sh | bash
```

That command downloads Droplet, checks its SHA-256 fingerprint, puts it in
Applications and opens it. There are no "unidentified developer" warnings.
Updating is the same line again.

## Quick start: one command on your Mac

```bash
./scripts/first-release.sh
```

It does steps 1–3 below for you: checks the developer tools, runs the
checks, creates and backs up the free signing certificate, pins the engine,
asks a few questions to write `release.env`, builds `dist/`, and offers to
install the result on your Mac. Run it again any time; finished steps are
skipped. Then upload (step 4) and test (step 5).

## Why the Terminal install (and no US$99 Apple account)

macOS only applies its "Apple could not verify this app is free of malware"
block to files that a **web browser** downloaded: browsers mark them as
"downloaded from the internet" (the quarantine flag). The only ways to avoid
the block for a browser download are a paid Apple Developer ID with
notarization (US$99/year) or asking customers to click through System
Settings → Privacy & Security → **Open Anyway** (since macOS 15 the old
right-click → Open shortcut is gone).

`curl` in Terminal does not set that flag, so the app simply opens. This is
how Homebrew and many other Mac tools are installed. Customers are trusting
your website, so publish the installer over https, keep it readable (people
can open `install.sh` in a browser to see what it does), and keep the
fingerprint check in it.

The release script also produces a DMG for customers who prefer a normal
download; they need the one-time **Open Anyway** step described below. If you
later buy the Apple developer membership, set a Developer ID identity in
`release.env` and the same script notarizes the app so the DMG opens with a
double-click too. Nothing else changes.

## 1. One-time setup

### Free signing certificate (2 minutes)

Every release must be signed with **the same** certificate. Then macOS
remembers customers' answers (Downloads folder access, Keychain access for the
license) across updates. A self-signed certificate is free:

1. Open **Keychain Access** (⌘ Space, type "Keychain Access").
2. Menu **Keychain Access → Certificate Assistant → Create a Certificate…**
3. Name: `Droplet Signing` · Identity Type: **Self Signed Root** ·
   Certificate Type: **Code Signing** → **Create** → **Done**.
4. Check it is there (it shows as not trusted; that is fine):
   ```bash
   security find-identity -p codesigning
   # 1) 1A2B… "Droplet Signing" (CSSMERR_TP_NOT_TRUSTED)
   ```
5. **Back it up**: in Keychain Access, right-click the certificate → Export →
   `.p12` with a password, and keep the file somewhere safe. If you lose it and
   sign with a new one, customers get permission prompts again after updating.

(`SIGNING_IDENTITY="-"` also works without any certificate, but then macOS
asks customers again for folder and Keychain access after every update.)

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

### Your website

Pick one https folder for Droplet's files, for example
`https://yourdomain.com/droplet/`. That is `DROPLET_DOWNLOAD_URL`; the
install command is always `<that folder>/install.sh`, so it never changes
between versions. Any static hosting works (your web host, GitHub Pages,
Netlify, Cloudflare Pages…), as long as it serves https.

The download page needs:

- The install command, with how to open Terminal (copy-paste text below).
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

Copy-paste text for the download page (replace the address):

```html
<h2>Install Droplet</h2>
<ol>
  <li>Open <strong>Terminal</strong>: press <kbd>⌘ Command</kbd> + <kbd>Space</kbd>,
      type <em>Terminal</em> and press <kbd>Return</kbd>.</li>
  <li>Paste this line and press <kbd>Return</kbd>:
    <pre><code>curl -fsSL https://yourdomain.com/droplet/install.sh | bash</code></pre></li>
  <li>Droplet opens and a little drop appears in your menu bar (top right).</li>
</ol>
<p>To update Droplet later, run the same line again. Requires macOS 14 Sonoma
or later on Apple Silicon or Intel.
<a href="https://yourdomain.com/droplet/install.sh">See exactly what the installer does.</a></p>

<details>
  <summary>Prefer a normal download?</summary>
  <ol>
    <li>Download <a href="https://yourdomain.com/droplet/Droplet-1.0.0.dmg">Droplet-1.0.0.dmg</a>,
        open it and drag Droplet into Applications.</li>
    <li>Open Droplet. macOS says it cannot verify the developer — click <strong>Done</strong>.</li>
    <li>Open <strong>System Settings → Privacy &amp; Security</strong>, scroll down and click
        <strong>Open Anyway</strong> next to "Droplet was blocked", then enter your password.</li>
  </ol>
  <p>This is needed once, because Droplet is sold directly rather than through the App Store.</p>
</details>
```

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
and offer its source (`SOURCES.txt` in the app lists the links). After pinning,
set `ffmpeg.version` and `ffmpeg.source` in `engine.lock.json` to the **exact**
source release and build configuration of the binaries you ship (for a GPL
build, the generic ffmpeg.org page is not enough). Replace the
`ffmpeg.download` URLs if you build or choose a different FFmpeg.

**Size.** Deno is large (roughly 100 MB per architecture). Without it, many
YouTube videos fail. To make a smaller download you can build separate Apple
Silicon and Intel releases (`DROPLET_ARCH=arm64` / `x86_64`) instead of one
universal app.

## 3. Build

```bash
cp release.env.example release.env   # once; it is git-ignored
$EDITOR release.env                  # bundle ID, version, certificate name, download folder, store IDs, links
./scripts/release.sh
```

The script validates the configuration first (`VALIDATE_ONLY=1` stops there),
then:

1. builds `Droplet` for arm64 and x86_64 and joins them with `lipo`;
2. assembles `Droplet.app` with the icon, third-party notices and the pinned
   helpers in `Contents/Helpers` (each helper is run once as a smoke test);
3. writes your bundle ID, version, store IDs and links into `Info.plist`;
4. signs every helper and then the app with `SIGNING_IDENTITY`;
5. writes to `dist/`:
   - `Droplet-<version>.zip` — what the installer downloads,
   - `install.sh` — the installer, with this version's address and SHA-256
     filled in,
   - `Droplet-<version>.dmg` — for the "normal download" option,
   - a `.sha256` file for the zip and the DMG,
   and prints the install command.

With a paid `Developer ID Application: …` identity and `NOTARY_PROFILE`, the
same run also uses the hardened runtime (with the minimal helper entitlements
in `Resources/Entitlements/`), notarizes and staples the app and the DMG, and
checks both with Gatekeeper.

## 4. Upload

Upload **`Droplet-<version>.zip`, `install.sh` and `Droplet-<version>.dmg`**
from `dist/` into your `DROPLET_DOWNLOAD_URL` folder. Upload the zip first and
`install.sh` last, so the installer never points at a file that is not there
yet. Keep older zips for a while: anyone halfway through an install still
finishes it.

Check it from any Mac:

```bash
curl -fsSL https://yourdomain.com/droplet/install.sh | head -15   # shows the new version
```

## 5. Test like a customer (before announcing a release)

On a Mac **without** Homebrew or Xcode (or a fresh macOS user account):

- [ ] Paste the install command into Terminal: Droplet installs into
      Applications and opens with no security warning.
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
- [ ] Run the install command again while Droplet is running: it quits,
      updates, reopens, and the license, free-download count and save folder
      are kept without new permission prompts.
- [ ] Quit from the bubble: no Droplet, yt-dlp, ffmpeg or deno processes remain.
- [ ] The DMG route: download it in Safari, drag to Applications, allow it once
      with **Open Anyway**, then make one download.

Then switch Lemon Squeezy to live mode, make one real purchase, refund it, and
confirm the refunded key stops working after the next daily check.

## 6. Every later release

1. Increase `DROPLET_VERSION` and `DROPLET_BUILD` in `release.env`.
2. Re-pin the engine (step 2) and commit `engine.lock.json`.
3. `./scripts/release.sh`, upload (step 4), run at least the install, one
   download and the license check from the checklist above.

Customers update by running the install command again. When a site breaks,
they can also press the update button in the bubble: it updates yt-dlp in the
background without a new app release. A new app release with a newer bundled
engine automatically takes precedence over an older in-app update.

## Optional later: paid Apple Developer ID

Only needed if you want the DMG to open with a plain double-click.

1. Join the [Apple Developer Program](https://developer.apple.com/programs/enroll/) (US$99/year).
2. In Xcode → Settings → Accounts → your team → **Manage Certificates…** → **+** →
   **Developer ID Application**. Check it:
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
4. In `release.env`: `SIGNING_IDENTITY="Developer ID Application: …"` and
   `NOTARY_PROFILE="droplet-notary"`. Keep the install command on your page.

Switching certificates changes the app's signature once, so existing
customers may see one permission prompt after that update. If notarization is
rejected, the script prints Apple's log; the usual causes are an unsigned
helper, a missing secure timestamp, or a wrong identity.

## Not included yet (decide before or after v1)

- **In-app "new version available".** Customers update by re-running the
  install command; the engine updates itself from the bubble. A version check
  against a small file on your site would be a simple later addition.
- **Mac App Store.** Not suitable for this design (bundled downloader,
  browser cookies, App Review guideline 5.2.3), and not needed.
- **Tamper-proof trial.** The free-download count is stored locally and can
  be reset by a determined user. That is a deliberate trade-off for a
  US$5 app (see the launch plan).
- **Legal review.** Payment-provider acceptance, consumer terms in your
  country, tax registration, and the GPL obligations of the bundled programs
  still need your own check (launch plan WHO-216/217/218/240).
