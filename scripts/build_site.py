#!/usr/bin/env python3
"""Builds Droplet's download website from website/ (called by scripts/release.sh).

The result is a folder of plain files (no server code) for any static host:
the download page with the install command, privacy policy, terms,
third-party licenses, install.sh and, for your own web host, the zip and DMG.

Values come from release.env. Every value is HTML-escaped and every link is
checked, so nothing in release.env can add markup or scripts to the pages.

With --launch-offer 1, customers choose their price from US$0 up to --price;
every price is the same full license. --launch-checkout-url is the https
address that receives the chosen price as ?price=2.50 and must check it again
before it starts a checkout. Without it the page says checkout isn't open.

--preview builds a local design preview (scripts/preview_site.py): the download
values may be left out, and every page says it is a preview and is not indexed."""
import argparse
import datetime
import html
from pathlib import Path
import re
import shutil
import sys

WEBSITE = Path(__file__).resolve().parents[1] / "website"
HTTPS = re.compile(r"https://[A-Za-z0-9.-]+(/[^\s\"'<>]*)?")
EMAIL = re.compile(r"(mailto:)?[^@\s/?\"'<>]+@[^@\s/?\"'<>]+\.[A-Za-z]+")
PRICE = re.compile(r"US\$([0-9]{1,3})(?:\.([0-9]{2}))?")
CONDITION = re.compile(r"<!-- if (\w+) -->(.*?)<!-- end \1 -->", re.S)
PLACEHOLDER = re.compile(r"\{\{(\w+)\}\}")
RAW = {"content", "license_links", "price_picks"}
REQUIREMENTS = {"universal": "Apple Silicon or Intel", "arm64": "Apple Silicon", "x86_64": "Intel"}
ASSETS = ("style.css", "site.js", "favicon.svg")
DOWNLOADS = ("download_url", "files_url", "installer", "zip", "dmg")
NOTICE_NAMES = {  # readable names for the files scripts/fetch_engine.py writes
    "README.txt": "About these programs",
    "SOURCES.txt": "Where to get the source code",
    "yt-dlp-LICENSE.txt": "yt-dlp license",
    "ffmpeg-LICENSE.txt": "FFmpeg license",
    "deno-LICENSE.txt": "Deno license",
}
PAGES = [  # template, output, title, body class
    ("index.html", "index.html", "Droplet: save videos from your Mac’s menu bar", "home"),
    ("privacy.html", "privacy/index.html", "Privacy policy · Droplet", "legal"),
    ("terms.html", "terms/index.html", "Terms of use · Droplet", "legal"),
    ("licenses.html", "licenses/index.html", "Third-party licenses · Droplet", "legal"),
]


class SiteError(Exception):
    pass


def fill(template, values, flags):
    """Keeps <!-- if flag --> blocks whose flag is set, then fills {{name}}."""
    previous = None
    while previous != template:  # conditions may be nested
        previous = template
        template = CONDITION.sub(lambda match: match.group(2) if flags.get(match.group(1)) else "", template)

    def value(match):
        name = match.group(1)
        if name not in values:
            raise SiteError(f"website template uses an unknown value: {name}")
        text = str(values[name])
        return text if name in RAW else html.escape(text, quote=True)
    return PLACEHOLDER.sub(value, template)


def support_link(support):
    if HTTPS.fullmatch(support):
        return support, support
    if EMAIL.fullmatch(support):
        address = support[len("mailto:"):] if support.startswith("mailto:") else support
        return f"mailto:{address}", address
    raise SiteError("the support contact must be an email address or an https link")


def money(cents):
    """US$0, US$3 or US$4.99."""
    return f"US${cents // 100}" + (f".{cents % 100:02d}" if cents % 100 else "")


def launch_limit(price):
    """The launch offer's highest price in cents: the regular price."""
    match = PRICE.fullmatch(price)
    cents = int(match[1]) * 100 + int(match[2] or 0) if match else 0
    if not cents:
        raise SiteError("the launch offer (DROPLET_LAUNCH_OFFER=1) needs DROPLET_PRICE like US$4.99: "
                        "customers choose a price from US$0 up to it")
    return cents


def build(args):
    given = [name for name in DOWNLOADS if getattr(args, name)]
    if 0 < len(given) < len(DOWNLOADS) or (not given and not args.preview):
        missing = ", ".join("--" + name.replace("_", "-") for name in DOWNLOADS if not getattr(args, name))
        raise SiteError(f"missing {missing}" + ("" if given else " (only a --preview can be built without the downloads)"))
    downloads = bool(given)
    if downloads:
        for name, url in (("download URL", args.download_url), ("DMG link", args.files_url)):
            if not HTTPS.fullmatch(url):
                raise SiteError(f"the {name} must be an https link: {url!r}")
        if not args.installer.is_file():
            raise SiteError(f"{args.installer} is missing")
    if args.checkout_url and not HTTPS.fullmatch(args.checkout_url):
        raise SiteError(f"the checkout link must be an https link: {args.checkout_url!r}")
    launch_checkout = args.launch_checkout_url.strip()
    # A GET form replaces a query in its address, so the address may not have one.
    if launch_checkout and (not HTTPS.fullmatch(launch_checkout) or "?" in launch_checkout or "#" in launch_checkout):
        raise SiteError(f"the launch checkout link must be an https link without ? or #: {launch_checkout!r}")
    if not args.owner.strip():
        raise SiteError("DROPLET_OWNER (your name or company) is required: the website names the seller")
    if not re.fullmatch(r"[0-9]{1,3}", args.refund_days):
        raise SiteError("DROPLET_REFUND_DAYS must be a number of days")
    price = args.price.strip()
    launch = args.launch_offer == "1"
    max_cents = launch_limit(price) if launch else 0
    support_href, support_text = support_link(args.support)
    download_url = args.download_url.rstrip("/") if downloads else ""
    files_url = args.files_url.rstrip("/") if downloads else ""
    dmg_name = args.dmg.name if downloads else ""

    out = args.output
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    for asset in ASSETS:
        shutil.copyfile(WEBSITE / asset, out / asset)
    shutil.copyfile(args.icon, out / "icon.png")
    if downloads:
        shutil.copyfile(args.installer, out / "install.sh")

    licenses = out / "licenses"
    licenses.mkdir()
    links = []
    names = set()
    for notice in sorted(args.notices.iterdir()) if args.notices else []:
        # Skips hidden files, such as the "._" copies macOS adds in zip archives.
        if notice.is_file() and notice.suffix == ".txt" and not notice.name.startswith("."):
            shutil.copyfile(notice, licenses / notice.name)
            names.add(notice.name)
            name = html.escape(notice.name, quote=True)
            label = html.escape(NOTICE_NAMES.get(notice.name, notice.name))
            links.append(f'          <li><a href="{name}">{label}</a><span class="file-name">{name}</span></li>')
    if not links:
        raise SiteError("no third-party license texts were found for the website")

    if downloads and args.include_downloads:
        for path in (args.zip, args.dmg):
            for item in (path, path.with_name(path.name + ".sha256")):
                shutil.copyfile(item, out / item.name)

    picks = [cents for cents in (0, 100, 300) if cents < max_cents] + [max_cents]
    values = {
        "version": args.version,
        "year": datetime.date.today().year,
        "owner": args.owner.strip(),
        "country": args.country.strip(),
        "price": price,
        "buy_label": f"Buy for {price}" if price else "Buy a license",
        "refund_days": args.refund_days,
        "support_href": support_href,
        "support_text": support_text,
        "install_command": f"curl -fsSL {download_url}/install.sh | bash" if downloads else "",
        "dmg_url": f"{files_url}/{dmg_name}" if downloads else "",
        "dmg_name": dmg_name,
        "checkout_url": args.checkout_url,
        "launch_checkout_url": launch_checkout,
        "launch_max": f"{max_cents // 100}.{max_cents % 100:02d}",
        "launch_max_cents": max_cents,
        "price_picks": "\n".join(
            f'              <button class="pick" type="button" data-price-pick="{cents}" '
            f'aria-pressed="{"true" if cents == max_cents else "false"}">{money(cents)}</button>'
            for cents in picks) if launch else "",
        "requirements": REQUIREMENTS[args.arch],
        "host": args.host,
        "address": args.address.strip(),
        "license_links": "\n".join(links),
        "description": "Droplet is a tiny menu-bar app for macOS that saves the video from a copied link as an MP4. "
                       "Your first three saved videos are free.",
    }
    sales_open = bool(args.checkout_url) or (launch and bool(launch_checkout))
    flags = {
        "preview": args.preview,
        "has_download": downloads,
        "no_download": not downloads,
        "has_price": bool(price),
        "launch_offer": launch,
        "no_launch_offer": not launch,
        "launch_checkout": launch and bool(launch_checkout),
        "launch_no_checkout": launch and not launch_checkout,
        "regular_checkout": not launch and bool(args.checkout_url),
        "regular_no_checkout": not launch and not args.checkout_url,
        "sales_open": sales_open,
        "sales_soon": not sales_open,
        "has_address": bool(args.address.strip()),
        "has_country": bool(args.country.strip()),
        "has_sources": "SOURCES.txt" in names,
    }
    layout = (WEBSITE / "layout.html").read_text()
    for template, output, title, page in PAGES:
        target = out / output
        target.parent.mkdir(parents=True, exist_ok=True)
        root = "../" * output.count("/")
        url = f"{download_url}/{output.removesuffix('index.html')}"
        page_values = dict(values, title=title, page=page, root=root, canonical_url=url, og_image=f"{download_url}/icon.png")
        content = fill((WEBSITE / template).read_text(), page_values, flags)
        target.write_text(fill(layout, dict(page_values, content=content), flags))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--download-url", default="", help="the website folder; install.sh is served from it")
    parser.add_argument("--files-url", default="", help="where the zip and DMG are served from")
    parser.add_argument("--installer", type=Path)
    parser.add_argument("--zip", type=Path)
    parser.add_argument("--dmg", type=Path)
    parser.add_argument("--include-downloads", action="store_true", help="copy the zip and DMG into the site")
    parser.add_argument("--notices", type=Path, help="the app's ThirdPartyNotices folder")
    parser.add_argument("--icon", type=Path, default=Path(__file__).resolve().parents[1] / "Resources/AppIcon.png")
    parser.add_argument("--owner", default="")
    parser.add_argument("--country", default="", help="the seller's country, shown with the seller's name")
    parser.add_argument("--support", required=True)
    parser.add_argument("--price", default="")
    parser.add_argument("--checkout-url", default="")
    parser.add_argument("--launch-offer", choices=("0", "1"), default="0",
                        help="1: customers choose a price from US$0 up to --price")
    parser.add_argument("--launch-checkout-url", default="", help="receives the chosen launch price as ?price=2.50")
    parser.add_argument("--refund-days", default="14")
    parser.add_argument("--address", default="")
    parser.add_argument("--arch", choices=sorted(REQUIREMENTS), default="universal")
    parser.add_argument("--host", default="our web host")
    parser.add_argument("--preview", action="store_true", help="a local design preview; downloads may be left out")
    args = parser.parse_args(argv)
    try:
        build(args)
    except (SiteError, OSError) as error:
        print(f"build_site: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
