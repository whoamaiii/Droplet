#!/usr/bin/env python3
"""Builds Droplet's download website from website/ (called by scripts/release.sh).

The result is a folder of plain files (no server code) for any static host:
the download page with the install command, privacy policy, terms,
third-party licenses, install.sh and, for your own web host, the zip and DMG.

Values come from release.env. Every value is HTML-escaped and every link is
checked, so nothing in release.env can add markup or scripts to the pages."""
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
CONDITION = re.compile(r"<!-- if (\w+) -->(.*?)<!-- end \1 -->", re.S)
PLACEHOLDER = re.compile(r"\{\{(\w+)\}\}")
RAW = {"content", "license_links"}
REQUIREMENTS = {"universal": "Apple Silicon or Intel", "arm64": "Apple Silicon", "x86_64": "Intel"}
PAGES = [  # template, output, title
    ("index.html", "index.html", "Droplet: save videos from your Mac's menu bar"),
    ("privacy.html", "privacy/index.html", "Privacy policy · Droplet"),
    ("terms.html", "terms/index.html", "Terms of use · Droplet"),
    ("licenses.html", "licenses/index.html", "Third-party licenses · Droplet"),
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


def build(args):
    for name, url in (("download URL", args.download_url), ("DMG link", args.files_url)):
        if not HTTPS.fullmatch(url):
            raise SiteError(f"the {name} must be an https link: {url!r}")
    if args.checkout_url and not HTTPS.fullmatch(args.checkout_url):
        raise SiteError(f"the checkout link must be an https link: {args.checkout_url!r}")
    if not args.owner.strip():
        raise SiteError("DROPLET_OWNER (your name or company) is required: the website names the seller")
    if not re.fullmatch(r"[0-9]{1,3}", args.refund_days):
        raise SiteError("DROPLET_REFUND_DAYS must be a number of days")
    if not args.installer.is_file():
        raise SiteError(f"{args.installer} is missing")
    support_href, support_text = support_link(args.support)
    download_url = args.download_url.rstrip("/")
    files_url = args.files_url.rstrip("/")
    dmg_name = args.dmg.name

    out = args.output
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    shutil.copyfile(WEBSITE / "style.css", out / "style.css")
    shutil.copyfile(args.icon, out / "icon.png")
    shutil.copyfile(args.installer, out / "install.sh")

    licenses = out / "licenses"
    licenses.mkdir()
    links = []
    for notice in sorted(args.notices.iterdir()) if args.notices else []:
        if notice.is_file() and notice.suffix == ".txt":
            shutil.copyfile(notice, licenses / notice.name)
            links.append(f'  <li><a href="{html.escape(notice.name, quote=True)}">{html.escape(notice.name)}</a></li>')
    if not links:
        raise SiteError("no third-party license texts were found for the website")

    if args.include_downloads:
        for path in (args.zip, args.dmg):
            for item in (path, path.with_name(path.name + ".sha256")):
                shutil.copyfile(item, out / item.name)

    values = {
        "version": args.version,
        "year": datetime.date.today().year,
        "owner": args.owner.strip(),
        "price": args.price.strip(),
        "buy_label": f"Buy for {args.price.strip()}" if args.price.strip() else "Buy a license",
        "refund_days": args.refund_days,
        "support_href": support_href,
        "support_text": support_text,
        "install_command": f"curl -fsSL {download_url}/install.sh | bash",
        "dmg_url": f"{files_url}/{dmg_name}",
        "dmg_name": dmg_name,
        "checkout_url": args.checkout_url,
        "requirements": REQUIREMENTS[args.arch],
        "host": args.host,
        "address": args.address.strip(),
        "license_links": "\n".join(links),
        "description": "Droplet saves video links as MP4 from your Mac's menu bar. Free for your first 3 videos.",
    }
    flags = {
        "has_checkout": bool(args.checkout_url),
        "no_checkout": not args.checkout_url,
        "has_price": bool(args.price.strip()),
        "has_address": bool(args.address.strip()),
    }
    layout = (WEBSITE / "layout.html").read_text()
    for template, output, title in PAGES:
        target = out / output
        target.parent.mkdir(parents=True, exist_ok=True)
        root = "../" * output.count("/")
        content = fill((WEBSITE / template).read_text(), values, flags)
        page = fill(layout, dict(values, content=content, title=title, root=root), flags)
        target.write_text(page)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--download-url", required=True, help="the website folder; install.sh is served from it")
    parser.add_argument("--files-url", required=True, help="where the zip and DMG are served from")
    parser.add_argument("--installer", type=Path, required=True)
    parser.add_argument("--zip", type=Path, required=True)
    parser.add_argument("--dmg", type=Path, required=True)
    parser.add_argument("--include-downloads", action="store_true", help="copy the zip and DMG into the site")
    parser.add_argument("--notices", type=Path, help="the app's ThirdPartyNotices folder")
    parser.add_argument("--icon", type=Path, default=Path(__file__).resolve().parents[1] / "Resources/AppIcon.png")
    parser.add_argument("--owner", default="")
    parser.add_argument("--support", required=True)
    parser.add_argument("--price", default="")
    parser.add_argument("--checkout-url", default="")
    parser.add_argument("--refund-days", default="14")
    parser.add_argument("--address", default="")
    parser.add_argument("--arch", choices=sorted(REQUIREMENTS), default="universal")
    parser.add_argument("--host", default="our web host")
    args = parser.parse_args(argv)
    try:
        build(args)
    except (SiteError, OSError) as error:
        print(f"build_site: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
