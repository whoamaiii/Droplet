#!/usr/bin/env python3
"""Builds and serves a local design preview of Droplet's website.

    python3 scripts/preview_site.py              build website-preview/ and serve it
    python3 scripts/preview_site.py --no-serve   only build it

The preview uses the seller details and the launch offer below, but no download
or checkout address, so those parts of the pages say they are not available yet.
The server listens on 127.0.0.1 only: other devices cannot open it, and nothing
is uploaded or published. Control-C stops it. Real builds come from
scripts/release.sh with the values in release.env."""
import argparse
import functools
import http.server
from pathlib import Path
import sys
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
import build_site  # noqa: E402

OUTPUT = ROOT / "website-preview"
NOTICES = "Droplet.app/Contents/Resources/ThirdPartyNotices/"
# Confirmed seller details and launch price.
SELLER = {"owner": "Whoamiii", "country": "Norway", "support": "quentin@whoamiii.art", "price": "US$4.99"}


class PreviewHandler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")  # a rebuild shows on the next reload
        super().end_headers()

    def log_message(self, *args):
        pass


def notices(work):
    """The license texts inside the newest release build in dist/, else the app's README note."""
    for archive in sorted((ROOT / "dist").glob("Droplet-*.zip"), reverse=True):
        with zipfile.ZipFile(archive) as bundle:
            names = [name[len(NOTICES):] for name in bundle.namelist() if name.startswith(NOTICES)]
            texts = [name for name in names if name.endswith(".txt") and "/" not in name and not name.startswith(".")]
            for name in texts:
                (work / name).write_bytes(bundle.read(NOTICES + name))
            if texts:
                return work, archive.name
    return ROOT / "Resources/ThirdPartyNotices", None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-serve", action="store_true", help="only build website-preview/")
    parser.add_argument("--version", default="1.0.0")
    args = parser.parse_args(argv)
    with tempfile.TemporaryDirectory() as raw:
        folder, source = notices(Path(raw))
        seller = [item for key, value in SELLER.items() for item in (f"--{key}", value)]
        failed = build_site.main(["--output", str(OUTPUT), "--preview", "--version", args.version,
                                  "--notices", str(folder), "--launch-offer", "1", *seller])
    if failed:
        return failed
    print(f"Built {OUTPUT}" + (f" (license texts from dist/{source})" if source else
                               " (no release build in dist/, so only the license README)"))
    if args.no_serve:
        return 0
    try:
        server = http.server.ThreadingHTTPServer(("127.0.0.1", args.port),
                                                 functools.partial(PreviewHandler, directory=str(OUTPUT)))
    except OSError as error:
        print(f"preview_site: port {args.port} is not free ({error.strerror}); try --port 8766", file=sys.stderr)
        return 1
    print(f"Preview: http://127.0.0.1:{args.port}/  (only this Mac can open it; Control-C stops it)", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
