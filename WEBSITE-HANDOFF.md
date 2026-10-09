# Droplet website: handoff (10 October 2026)

The website redesign is built and checked locally. Nothing has been committed,
pushed, published or deployed, and no domain, store or checkout was touched.

## Preview

- **Open:** http://127.0.0.1:8765/ (pages: `/privacy/`, `/terms/`, `/licenses/`).
  The server listens on 127.0.0.1 only, so only this Mac can open it.
- **Files:** `/Users/quentinthiessen/Desktop/Droplet/website-preview/` (generated, git-ignored).
- **Start it again** (after a restart, for example), in Terminal in the project folder:

  ```bash
  python3 scripts/preview_site.py
  ```

  Control-C stops it. `--no-serve` only builds; `--port 8766` picks another port.
  To stop the copy left running now: `kill $(lsof -ti tcp:8765)`.
- The preview uses the confirmed details (seller **Whoamiii**, **Norway**,
  **quentin@whoamiii.art**, US$4.99, launch offer on) and **no** download or checkout
  address. Every page carries a "Local design preview" bar and `noindex`; the install
  line and the checkout button show clear "not available yet" states.

## What the site contains

Home page: hero with the launch offer, "Try it free" and "Choose your price"; an
interactive, clearly labelled illustration of the menu-bar window (real layout,
texts, stages, icon changes and trial counter; cancel never uses a free download);
how it works; features; pricing (price chooser plus a separate free-trial panel);
install; FAQ with support; responsible-use note. Privacy, terms and third-party
licenses pages share a readable document layout. Light and dark mode follow macOS.
No web fonts, trackers or external requests: about 25 KB compressed (HTML, CSS, JS),
plus the 125 KB app icon, which loads lazily.

## Changed files

- Website templates: `website/layout.html`, `index.html`, `privacy.html`, `terms.html`,
  `licenses.html`, `style.css` (rewritten); `website/site.js` and `website/favicon.svg` (new).
- `scripts/build_site.py`: `--preview`, `--launch-offer`, `--launch-checkout-url`,
  `--country`; copies the new assets; canonical and Open Graph links from
  `DROPLET_DOWNLOAD_URL`; readable license names; skips hidden `._` files.
  All values stay HTML-escaped and links are still checked.
- `scripts/preview_site.py` (new): builds and serves the preview on 127.0.0.1.
- `scripts/release.sh`: passes the three new optional values to the website and
  checks them before the build. Build, signing, notarization and publishing are unchanged.
- Tests: `Tests/Distribution/test_publish.py` (6 new website tests),
  `Tests/Distribution/test_release.py` (1 new test).
- Docs: `release.env.example`, `docs/release/RELEASE.md`,
  `docs/engineering/ARCHITECTURE.md`, `.gitignore` (`website-preview/`), this file.
- Not touched: the Swift app, licensing engine, installer, signing, `publish.sh`,
  `first-release.sh`, `release.env` and `dist/`.

## Test results

- Distribution suite (`python3 -m unittest discover -s Tests/Distribution`, macOS bash 3.2):
  **50 tests, 49 pass.** The one failure,
  `test_install…test_actual_kernel_executable_path_rejects_running_target`,
  failed identically before any change (also outside the sandbox). It belongs to the
  developer installer (`scripts/install_app.py`), which this work did not touch.
- Website tests: 10 of 10 (4 existing, 6 new: launch offer, checkout address,
  setting checks, preview mode, license names, the price parser in Node.js).
- Browser checks with headless Chromium and WebKit (Safari's engine), using a locally
  cached Playwright; the scripts are not part of the repository:
  - 106 of 106 interaction checks in each engine. Price boundaries 0, 0.01, 4.98 and 4.99
    accepted; 5, 5.00, 4.995, -1, letters, empty and "." refused with an accessible
    message (`aria-invalid`, live region, focus returns to the field). Comma decimals
    and `$`/`US$` prefixes accepted. Slider keys (arrows, Page Up/Down, Home, End) and
    quick picks work by keyboard. The unavailable checkout explains itself and never
    navigates. Also checked: demo flow, cancel, trial counter, Escape, skip link,
    visible focus, reduced motion (animations off, demo still works).
  - Configured build (stand-in addresses): Copy puts exactly the install line on the
    clipboard; when copying is refused, the page says so and selects the line. The
    chosen price reaches the checkout address as `?price=2.50` or `?price=0.00`;
    invalid prices never leave the page.
  - Link crawl: every local link and anchor resolves.
  - Viewed at 1440×900, 1366×768, 1280×800, 1024×768, 768×1024, 390×844, 375×667 and
    320×640 in light and dark, plus forced colours (high contrast). No horizontal
    scrolling. The first-screen buttons are visible everywhere except 320×640, and there
    only because of the preview bar.
- Not checked: VoiceOver with a real screen reader, a real checkout, and the real install
  command (no download address exists yet).

## Before launch: checkout, US$0 licenses and the US$4.99 cap

The price chooser only checks the amount in the browser. It does not enforce
the provider's checkout price and does not create licenses. Remaining setup:

1. **Lemon Squeezy store and product** with license keys on (set the activation limit
   and no expiry), approved by Lemon Squeezy, including their prohibited-products check
   for a video downloader (not yet confirmed).
2. **The cap.** Lemon Squeezy's pay-what-you-want has a minimum and a suggested price,
   but no documented maximum
   ([docs](https://docs.lemonsqueezy.com/help/products/pay-what-you-want)). So a small
   server-side **price service** is needed at `DROPLET_LAUNCH_CHECKOUT_URL`. It takes
   `GET ?price=2.50`, checks 0.00 to 4.99 again on the server, then creates a checkout
   through Lemon Squeezy's API with `custom_price` in cents. It keeps the API key secret
   on the server and redirects the customer to the checkout.
3. **US$0.** The API describes `custom_price` as "a positive integer in cents", so
   US$0 needs another route, for example a US$0 variant of the same product or a 100%
   discount code applied by the service. Whether a US$0 order emails a license key is not
   documented: test it in test mode first.
4. **Same license everywhere.** The app accepts keys from any variant of the configured
   product while `DROPLET_LS_VARIANT_ID` is empty. Keep launch variants under the same
   product and leave that value empty.
5. **App Buy button.** During the offer, set `DROPLET_CHECKOUT_URL` to the site's price
   section (`https://<domain>/#price`). After the offer, set `DROPLET_LAUNCH_OFFER=0`,
   point `DROPLET_CHECKOUT_URL` at the regular US$4.99 checkout, and rebuild.
6. **Test in Lemon Squeezy test mode**: US$0, 0.01, 2.50 and 4.99 succeed and their keys
   activate in Droplet; 5.00 and malformed prices are refused by the service; refunds work.

## Domain and hosting

No domain is written into the site. The site's own address (install line, canonical
links) comes from `DROPLET_DOWNLOAD_URL`. After buying the domain, set in `release.env`
(single quotes): `DROPLET_DOWNLOAD_URL`, `DROPLET_WEBSITE_URL`, `DROPLET_PRIVACY_URL`
(`…/privacy/`), `DROPLET_OWNER='Whoamiii'`, `DROPLET_COUNTRY='Norway'`,
`DROPLET_SUPPORT='quentin@whoamiii.art'`, `DROPLET_PRICE='US$4.99'`,
`DROPLET_LAUNCH_OFFER='1'`, `DROPLET_LAUNCH_CHECKOUT_URL`, the store IDs and
`DROPLET_BUNDLE_ID='io.github.whoamaiii.droplet'`. Then `./scripts/release.sh`
builds `dist/site/`; publishing remains a separate, approved step.

- `release.env` still holds test values from the 9 October QA run (`invalid.droplet-test…`).
  They must be replaced before a real build.
- `publish.sh` supports a `github.io` address or uploading to your own web host. A custom
  domain on GitHub Pages is not supported by the current scripts; choose a host, or extend
  the script later.

## Details that must come from you (not invented)

- **Legal identity.** "Whoamiii" is a display name. A privacy policy has to name the data
  controller (GDPR Article 13), and Norway's e-commerce act (ehandelsloven § 8) asks for
  the provider's name, geographic address and organisation number if registered. The
  site shows only "Whoamiii, Norway" and the email. `DROPLET_ADDRESS` can add an address.
- **Refund period:** 14 days is the project's existing default (`DROPLET_REFUND_DAYS`).
  Confirm it.
- **Activation limit** (number of Macs) is set in Lemon Squeezy; the site says "the
  number stated at checkout".
- **Withdrawal rights and checkout consent** for EU/EEA consumers are handled by Lemon
  Squeezy as merchant of record. Confirm in the store settings.
- Have the privacy policy and terms reviewed for Norway and the EU (this is not legal advice).

## Notes

- The demo's example is the Blender Foundation's *Big Buck Bunny* (CC BY 3.0), the
  video downloaded in the 9 October release QA. Vimeo is not advertised, because it
  needed a login in that QA.
- If a paid Developer ID with notarization is added later, update the DMG and Terminal
  wording in `website/index.html`: it assumes the current self-signed builds.
- Safari's default keyboard setting moves Tab between form fields only; Option-Tab (or
  "Press Tab to highlight each item") reaches every link and button.
