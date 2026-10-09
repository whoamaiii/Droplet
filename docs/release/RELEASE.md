# Releasing Droplet on your website

Droplet is distributed **from your own website**, never through the Mac App
Store, and **without a paid Apple developer account**. Customers install it
with one line in Terminal:

```bash
curl -fsSL https://yourname.github.io/droplet/install.sh | bash
```

That command downloads Droplet, checks its SHA-256 fingerprint, puts it in
Applications and opens it. There are no "unidentified developer" warnings.
Updating is the same line again. The website with that command, the price,
privacy policy and terms is generated for you, and can be hosted for free on
GitHub Pages or uploaded to your own web host.

## Quick start: one command on your Mac

```bash
./scripts/first-release.sh
```

It does steps 1–4 below for you: checks the developer tools, runs the
checks, creates and backs up the free signing certificate, pins the engine,
asks a few questions to write `release.env` (hosting, app identifier, support
email, your name, price, Lemon Squeezy IDs), builds the app and its website
into `dist/`, offers to install it on your Mac, and offers to publish it. Run
it again any time; finished steps are skipped (`--new-settings` asks the
questions again and keeps the old answers as `release.env.old-…`). Then test
like a customer (step 5).

### The order that works best

1. Run `./scripts/first-release.sh` and choose the free GitHub website. Leave
   the Lemon Squeezy questions empty for now.
2. Put that trial-only version online: `./scripts/publish.sh --trial-only`.
   Install it with the command from the live site on your Mac (the
   customer's path). The page says "License sales open soon".
3. Sign up at Lemon Squeezy and apply for store activation, giving that
   website: reviewers want to see the product, price, terms, privacy policy
   and contact.
4. While you wait, set up the product in **test mode** and test a purchase
   with a local build (see "Lemon Squeezy" below).
5. Once the store is live: put the **live** IDs and checkout link in
   `release.env`, delete the `ALLOW_UNLICENSED` line, raise `DROPLET_VERSION`
   (for example to 1.0.1) and `DROPLET_BUILD`, then run
   `./scripts/first-release.sh` again and answer **y** to publish. Everyone
   who installed the trial version gets the Buy button by running the install
   command again.

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
`com.yourdomain.droplet`, or `io.github.yourname.droplet` with the free GitHub
website (the wizard suggests it). Never change it after the first public release:
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
4. Use **test mode** for your first end-to-end test: put the test-mode IDs
   and checkout link in `release.env`, build, install it on your Mac (answer
   **n** to publishing), buy with a test card, take the key from the receipt
   email, activate it in Droplet, deactivate it.
5. After the store is activated, copy the product to **live mode** (the
   product's menu → Copy to live mode). Live mode has its **own product ID
   and checkout link**: put those in `release.env` before the public build.
   A build only accepts keys of the product IDs it was built with.

How the app uses it: the key is activated with Lemon Squeezy's public License
API (no secret API key is shipped). The app checks that the key belongs to
your store and product, stores it in the Keychain, re-checks at most once a
day, and keeps working for 30 days without internet. Only an authoritative
answer from Lemon Squeezy (unknown key, disabled, refunded, deactivated)
removes it. Settings → License has **Buy**, **Activate**, **Check license**
and **Deactivate this Mac**.

### Your website

`./scripts/release.sh` builds the whole website into `dist/site/` from the
templates in `website/` and the values in `release.env`:

- the **download page** with the install command (and a copy button), the
  DMG as a fallback, what Droplet does, the trial (3 saved videos), the
  price and Buy button (or "License sales open soon" without a store), the
  requirements (macOS 14 Sonoma or later), questions and answers, and a
  note to only download videos you have the right to download;
- `privacy/`: the privacy policy (from
  [PRIVACY-POLICY-TEMPLATE.md](PRIVACY-POLICY-TEMPLATE.md));
- `terms/`: terms of use, with your refund promise (`DROPLET_REFUND_DAYS`,
  14 by default) and Lemon Squeezy as merchant of record;
- `licenses/`: the third-party licenses and source links of the bundled
  programs, with the written source offer;
- `install.sh` and, for your own web host, the zip and DMG.

The seller name (`DROPLET_OWNER`), support email and price come from
`release.env`; `DROPLET_ADDRESS` adds a postal address to the legal pages if
your country requires one. Have the texts checked for your country (this is
not legal advice). To change wording, edit `website/` and build again.

**Free hosting on GitHub (recommended).** The wizard sets
`DROPLET_GITHUB_REPO=yourname/yourname.github.io` and
`DROPLET_DOWNLOAD_URL=https://yourname.github.io/droplet`.
`./scripts/publish.sh` then creates that **public** repository if needed,
uploads the zip and DMG to a GitHub release (no size limit worries), puts the
website in its `droplet/` folder, turns on GitHub Pages, waits until the
install command works online and downloads the zip once to check its
fingerprint. It needs GitHub's command-line tool once:

```bash
brew install gh
gh auth login        # GitHub.com → HTTPS → log in with a web browser
```

Only the website repository is public; Droplet's source code stays private.
Other files in an existing `yourname.github.io` repository are kept.

**Your own web host.** Pick one https folder for Droplet, for example
`https://yourdomain.com/droplet/`. That is `DROPLET_DOWNLOAD_URL`; the install
command is always `<that folder>/install.sh`, so it never changes between
versions. `./scripts/publish.sh` tells you to upload everything in
`dist/site/` there (zip and DMG first, `install.sh` last), and
`./scripts/publish.sh --check` then verifies what is online.

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
and offer its source (`SOURCES.txt` in the app lists the links). Pinning reads
the FFmpeg release from the build address and records it in `ffmpeg.version`
and `ffmpeg.source` (the matching ffmpeg.org source archive); `ffmpeg.build`
names the public build script these binaries come from. If the version cannot
be read (other download addresses), set those fields by hand to the **exact**
source release and build configuration of the binaries you ship. Replace the
`ffmpeg.download` URLs and `ffmpeg.build` if you build or choose a different
FFmpeg. The GPL builds also contain libraries such as x264; for the strongest
position, keep a copy of the complete source you ship (FFmpeg plus the
libraries the build script downloads) and host it next to your releases, or
ship an LGPL build instead. This is not legal advice.

The FFmpeg builder has said it will stop making Intel builds. The pinned Intel
files keep working; if they ever disappear, build Apple Silicon only
(`DROPLET_ARCH=arm64`) or pick another Intel FFmpeg.

**Size.** Deno is large (roughly 100 MB per architecture). Without it, many
YouTube videos fail. To make a smaller download you can build separate Apple
Silicon and Intel releases (`DROPLET_ARCH=arm64` / `x86_64`) instead of one
universal app.

## 3. Build

```bash
cp release.env.example release.env   # once (or let first-release.sh write it); git-ignored
$EDITOR release.env                  # bundle ID, version, certificate, website, seller, price, store IDs
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
   - `site/` — the website to publish (see "Your website"),
   and prints the install command.

With a paid `Developer ID Application: …` identity and `NOTARY_PROFILE`, the
same run also uses the hardened runtime (with the minimal helper entitlements
in `Resources/Entitlements/`), notarizes and staples the app and the DMG, and
checks both with Gatekeeper.

## 4. Publish

```bash
./scripts/publish.sh               # asks before anything goes public
./scripts/publish.sh --check       # only check what is online
./scripts/publish.sh --trial-only  # also allow a build without a store
```

It first checks that `dist/` really is the build `release.env` describes and
refuses a build without a Lemon Squeezy store unless you say `--trial-only`.
Files go online in a safe order: zip and DMG first, website and `install.sh`
last, so the install command never points at a file that is not there yet.
Publishing the same version again asks before replacing its files. At the
end it prints the live download page and install command.

## 5. Test like a customer (before announcing a release)

On a Mac **without** Homebrew or Xcode (or a fresh macOS user account):

- [ ] Open the live download page: the install command, price, privacy
      policy, terms and license links are right.
- [ ] Copy the install command from the page into Terminal: Droplet installs
      into Applications and opens with no security warning.
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
3. `./scripts/release.sh`, then `./scripts/publish.sh` (step 4), and run at
   least the install, one download and the license check from the checklist
   above.

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
